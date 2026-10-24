package io.whitelink.android

import android.Manifest
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.nekohasekai.libbox.Libbox
import io.whitelink.android.data.ProfileStore
import io.whitelink.android.data.SelectedMode
import io.whitelink.android.data.Snapshot
import io.whitelink.android.data.SubscriptionRepository
import io.whitelink.android.data.ConfigurationParser
import io.whitelink.android.vpn.VpnController
import io.whitelink.android.vpn.VpnPhase
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.text.DateFormat
import java.util.Date

class MainActivity : ComponentActivity() {
    private val vpnPermission = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        if (it.resultCode == RESULT_OK) VpnController.connect(this)
    }
    private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme(colorScheme = darkColorScheme(
                primary = Color(0xFF61DBC5), onPrimary = Color(0xFF082720),
                background = Color(0xFF101720), surface = Color(0xFF182330),
                surfaceVariant = Color(0xFF243242), onBackground = Color(0xFFF1F6FA),
                onSurface = Color(0xFFF1F6FA), secondary = Color(0xFFAFC2D4)
            )) { Surface(Modifier.fillMaxSize()) { WhiteLinkScreen(::requestConnect) } }
        }
    }

    private fun requestConnect() {
        if (Build.VERSION.SDK_INT >= 33) notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        val permission = VpnService.prepare(this)
        if (permission == null) VpnController.connect(this) else vpnPermission.launch(permission)
    }

    @Composable
    @OptIn(ExperimentalMaterial3Api::class)
    private fun WhiteLinkScreen(start: () -> Unit) {
        val store = remember { ProfileStore(this) }
        val repository = remember {
            SubscriptionRepository(store, BuildConfig.DEBUG) { outbound ->
                val node = JSONObject(outbound).put("tag", "proxy")
                Libbox.checkConfig(JSONObject()
                    .put("outbounds", JSONArray().put(node))
                    .put("route", JSONObject().put("final", "proxy"))
                    .toString())
            }
        }
        val state by VpnController.state.collectAsState()
        val logs by VpnController.logs.collectAsState()
        val scope = rememberCoroutineScope()
        var snapshot by remember { mutableStateOf(Snapshot()) }
        var selected by remember { mutableStateOf(SelectedMode.VLESS) }
        var loadError by remember { mutableStateOf<String?>(null) }
        var tab by remember { mutableIntStateOf(0) }
        var busy by remember { mutableStateOf(false) }
        var message by remember { mutableStateOf<String?>(null) }
        var source by remember { mutableStateOf("") }
        var dialog by remember { mutableStateOf<SelectedMode?>(null) }
        var importText by remember { mutableStateOf("") }
        var clearPrompt by remember { mutableStateOf(false) }
        var search by remember { mutableStateOf("") }
        var count by remember { mutableStateOf("30") }
        val idle = state.isIdle && VpnController.isIdle

        LaunchedEffect(Unit) {
            withContext(Dispatchers.IO) {
                runCatching { store.load() }.onSuccess {
                    snapshot = it; source = it.source ?: ""; selected = it.selectedMode
                    count = it.turn?.let { turn -> JSONObject(turn).getJSONObject("proxy").getInt("num_conns").toString() } ?: "30"
                }
                    .onFailure { loadError = "Не удалось прочитать защищённые настройки. Выполните повторный импорт." }
            }
        }
        LaunchedEffect(state.mode, state.phase) { if (!idle) selected = state.mode }

        fun runImport(operation: suspend () -> Unit) {
            busy = true
            scope.launch {
                try {
                    withContext(Dispatchers.IO) { operation() }
                    snapshot = withContext(Dispatchers.IO) { store.load() }
                    source = snapshot.source ?: ""
                    selected = snapshot.selectedMode
                    count = withContext(Dispatchers.IO) { store.connections().toString() }
                    loadError = null
                } catch (e: Exception) {
                    message = e.message?.take(300) ?: "Не удалось импортировать настройки."
                } finally { busy = false }
            }
        }

        val fileImport = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
            if (uri != null && idle) runImport {
                val text = contentResolver.openInputStream(uri)?.use { input ->
                    val bytes = ByteArrayOutputStream()
                    val block = ByteArray(8192)
                    while (true) {
                        val n = input.read(block)
                        if (n < 0) break
                        if (bytes.size() + n > 8 * 1024 * 1024) error("JSON превышает лимит 8 МиБ.")
                        bytes.write(block, 0, n)
                    }
                    ConfigurationParser.decodeUtf8(bytes.toByteArray())
                } ?: error("Файл недоступен.")
                repository.importVless(text)
                message = "VLESS-конфигурация сохранена."
            }
        }
        val exportCsv = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("text/csv")) { uri ->
            if (uri != null) scope.launch(Dispatchers.IO) {
                runCatching {
                    val file = VpnController.diagnosticsFile(this@MainActivity) ?: error("Диагностика пока пуста.")
                    contentResolver.openOutputStream(uri)?.use { output -> file.inputStream().use { it.copyTo(output) } }
                        ?: error("Не удалось записать файл.")
                }.onFailure { message = it.message }.onSuccess { message = "CSV сохранён." }
            }
        }
        val exportLogs = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("text/plain")) { uri ->
            if (uri != null) scope.launch(Dispatchers.IO) {
                runCatching { contentResolver.openOutputStream(uri)?.bufferedWriter()?.use { it.write(logs.joinToString("\n")) } }
                    .onSuccess { message = "Журнал сохранён." }.onFailure { message = "Не удалось сохранить журнал." }
            }
        }

        Column(Modifier.fillMaxSize().systemBarsPadding().imePadding()) {
            Row(Modifier.fillMaxWidth().padding(24.dp, 20.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("WhiteLink", fontSize = 27.sp, fontWeight = FontWeight.Bold)
                    Text("VPN · белые списки", color = MaterialTheme.colorScheme.secondary, fontSize = 13.sp)
                }
                Surface(color = MaterialTheme.colorScheme.surfaceVariant, shape = MaterialTheme.shapes.small) {
                    Text("TEST 0.1", Modifier.padding(10.dp, 6.dp), fontSize = 11.sp)
                }
            }
            PrimaryTabRow(selectedTabIndex = tab) {
                listOf("Подключение", "Настройки", "Журнал").forEachIndexed { index, title ->
                    Tab(selected = tab == index, onClick = { tab = index }, text = { Text(title) })
                }
            }
            if (tab == 0) Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text(phaseLabel(state.phase), fontSize = 23.sp, fontWeight = FontWeight.SemiBold,
                            color = if (state.phase == VpnPhase.CONNECTED) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface)
                        Text(if (selected == SelectedMode.DIRECT) "Диагностика: трафик идёт напрямую" else "Один VPN-туннель · общая маршрутизация",
                            color = MaterialTheme.colorScheme.secondary)
                        state.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                        loadError?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                        val canStart = when (selected) {
                            SelectedMode.VLESS -> snapshot.vless != null
                            SelectedMode.TURN -> snapshot.turn != null
                            SelectedMode.DIRECT -> true
                        }
                        Button(onClick = { if (idle) start() else VpnController.disconnect(this@MainActivity) },
                            enabled = !busy && state.phase != VpnPhase.STOPPING && (!idle || canStart),
                            modifier = Modifier.fillMaxWidth().height(54.dp)) {
                            Text(if (idle) (if (selected == SelectedMode.DIRECT) "Запустить прямой режим" else "Подключить") else "Отключить", fontSize = 16.sp)
                        }
                        if (!canStart) Text("Добавьте настройки этого режима во вкладке «Настройки».", fontSize = 13.sp)
                    }
                }
                Text("РЕЖИМ ПОДКЛЮЧЕНИЯ", fontSize = 12.sp, color = MaterialTheme.colorScheme.secondary)
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    listOf(SelectedMode.VLESS, SelectedMode.TURN).forEach { mode ->
                        val available = if (mode == SelectedMode.VLESS) snapshot.vless != null else snapshot.turn != null
                        FilterChip(selected = selected == mode, onClick = {
                            selected = mode
                            VpnController.switchMode(this@MainActivity, mode)
                        }, enabled = available && !busy && (idle || state.phase == VpnPhase.CONNECTED),
                            label = { Text(if (mode == SelectedMode.VLESS) "VLESS" else "VK TURN") })
                    }
                }
                if (selected == SelectedMode.DIRECT) Text("Выбран прямой диагностический режим. VPN-шифрование и обход ограничений не применяются.", color = MaterialTheme.colorScheme.error)
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    StatCard("↓ Загрузка", "${bytes(state.rxSpeed)}/с", "Всего ${bytes(state.rxBytes)}", Modifier.weight(1f))
                    StatCard("↑ Отправка", "${bytes(state.txSpeed)}/с", "Всего ${bytes(state.txBytes)}", Modifier.weight(1f))
                }
                if (state.phase == VpnPhase.CONNECTED) {
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        StatCard("TURN-сессии", state.allocations.toString(), if (state.mode == SelectedMode.TURN) "Установленные соединения" else "Режим ${modeLabel(state.mode)}", Modifier.weight(1f))
                        StatCard("Память RSS", if (state.rssBytes > 0) bytes(state.rssBytes) else "—", if (state.pssBytes > 0) "PSS ${bytes(state.pssBytes)}" else "Процесс приложения", Modifier.weight(1f))
                    }
                }
                Text("Белые списки и локальные адреса идут напрямую. Реклама и заданные категории блокируются. Остальной трафик — через выбранный режим.", fontSize = 13.sp, color = MaterialTheme.colorScheme.secondary)
                if (snapshot.updatedAt > 0) Text("Настройки сохранены: ${DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date(snapshot.updatedAt))}", fontSize = 12.sp, color = MaterialTheme.colorScheme.secondary)
            }
            if (tab == 1) Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Text("Подписка", fontSize = 21.sp, fontWeight = FontWeight.SemiBold)
                Text("Одна ссылка содержит настройки VLESS и VK TURN. Сохранённые настройки доступны без повторной загрузки.", fontSize = 13.sp, color = MaterialTheme.colorScheme.secondary)
                OutlinedTextField(value = source, onValueChange = { source = it }, modifier = Modifier.fillMaxWidth(),
                    enabled = idle && !busy, label = { Text("Ссылка подписки") }, singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
                Button(onClick = { runImport {
                    val result = repository.update(source.trim())
                    message = if (result.warnings.isEmpty()) "Подписка обновлена." else result.warnings.joinToString("\n")
                } }, enabled = idle && !busy && source.isNotBlank(), modifier = Modifier.fillMaxWidth()) {
                    Text(if (busy) "Загрузка…" else "Загрузить / обновить")
                }
                if (!idle) Text("Импорт и обновление доступны после отключения VPN.", color = MaterialTheme.colorScheme.secondary, fontSize = 13.sp)
                HorizontalDivider()
                Text("Ручной импорт", fontSize = 19.sp, fontWeight = FontWeight.SemiBold)
                OutlinedButton(onClick = { dialog = SelectedMode.VLESS; importText = "" }, enabled = idle && !busy, modifier = Modifier.fillMaxWidth()) { Text("Вставить VLESS JSON") }
                OutlinedButton(onClick = { fileImport.launch(arrayOf("application/json", "text/*", "application/octet-stream")) }, enabled = idle && !busy, modifier = Modifier.fillMaxWidth()) { Text("Открыть JSON-файл") }
                OutlinedButton(onClick = { dialog = SelectedMode.TURN; importText = "" }, enabled = idle && !busy, modifier = Modifier.fillMaxWidth()) { Text("Вставить TURN-ссылку") }
                HorizontalDivider()
                Text("VK TURN", fontSize = 19.sp, fontWeight = FontWeight.SemiBold)
                OutlinedTextField(value = count, onValueChange = { value ->
                    if (value.length <= 2 && value.all(Char::isDigit)) {
                        count = value
                        value.toIntOrNull()?.takeIf { it in 1..50 }?.let { n ->
                            scope.launch(Dispatchers.IO) { runCatching { store.setConnections(n) }.onFailure { message = it.message } }
                        }
                    }
                }, label = { Text("Число соединений (1–50)") }, modifier = Modifier.fillMaxWidth(),
                    enabled = idle && selected != SelectedMode.VLESS,
                    isError = count.toIntOrNull() !in 1..50,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
                Text("Статистика показывает установленные TURN-сессии. Android использует отдельный ID установки.", fontSize = 12.sp, color = MaterialTheme.colorScheme.secondary)
                HorizontalDivider()
                OutlinedButton(onClick = {
                    selected = SelectedMode.DIRECT
                    VpnController.switchMode(this@MainActivity, selected); tab = 0
                }, enabled = idle && !busy, modifier = Modifier.fillMaxWidth()) { Text("Диагностика: прямой режим") }
                Text("В этом режиме трафик идёт напрямую; он позволяет сравнить работу сети и памяти.", fontSize = 12.sp, color = MaterialTheme.colorScheme.secondary)
                TextButton(onClick = { clearPrompt = true }, enabled = idle && !busy) { Text("Удалить сохранённые подключения", color = MaterialTheme.colorScheme.error) }
                Text("WhiteLink 0.1.0 · Android 7+ · sing-box\nИсходники и лицензии входят в комплект тестовой сборки.", fontSize = 12.sp, color = MaterialTheme.colorScheme.secondary)
            }
            if (tab == 2) Column(Modifier.weight(1f).padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = { exportCsv.launch("whitelink-diagnostics.csv") }, modifier = Modifier.weight(1f)) { Text("Экспорт CSV") }
                    OutlinedButton(onClick = { exportLogs.launch("whitelink-log.txt") }, modifier = Modifier.weight(1f)) { Text("Сохранить журнал") }
                }
                OutlinedTextField(value = search, onValueChange = { search = it }, singleLine = true, label = { Text("Поиск в журнале") }, modifier = Modifier.fillMaxWidth())
                Text("Последние ${logs.size} строк · секреты скрыты", color = MaterialTheme.colorScheme.secondary, fontSize = 12.sp)
                val visible = logs.filter { search.isBlank() || it.contains(search, ignoreCase = true) }
                Text(if (visible.isEmpty()) "Здесь появятся события подключения и ошибки ядра." else visible.joinToString("\n"),
                    modifier = Modifier.fillMaxWidth().weight(1f).background(MaterialTheme.colorScheme.background).verticalScroll(rememberScrollState()).padding(8.dp),
                    fontSize = 11.sp, lineHeight = 16.sp)
            }
        }
        message?.let { body -> AlertDialog(onDismissRequest = { message = null }, title = { Text("WhiteLink") }, text = { Text(body) }, confirmButton = { TextButton(onClick = { message = null }) { Text("OK") } }) }
        dialog?.let { mode -> AlertDialog(onDismissRequest = { if (!busy) dialog = null },
            title = { Text(if (mode == SelectedMode.VLESS) "Импорт VLESS" else "Импорт VK TURN") },
            text = { OutlinedTextField(value = importText, onValueChange = { importText = it }, modifier = Modifier.fillMaxWidth().heightIn(min = 150.dp, max = 320.dp), label = { Text(if (mode == SelectedMode.VLESS) "JSON outbound или outbounds" else "wdtt:// или vkturnproxy://") }) },
            confirmButton = { TextButton(enabled = !busy && importText.isNotBlank(), onClick = {
                val input = importText
                dialog = null; importText = ""
                runImport {
                    if (mode == SelectedMode.VLESS) repository.importVless(input) else repository.importTurn(input)
                    message = "Настройки ${modeLabel(mode)} сохранены."
                }
            }) { Text("Импортировать") } }, dismissButton = { TextButton(onClick = { dialog = null; importText = "" }) { Text("Отмена") } }) }
        if (clearPrompt) AlertDialog(onDismissRequest = { clearPrompt = false }, title = { Text("Удалить подключения?") }, text = { Text("Потребуется повторно импортировать подписку или настройки.") },
            confirmButton = { TextButton(onClick = { clearPrompt = false; runImport { repository.clear(); message = "Настройки удалены." } }) { Text("Удалить") } },
            dismissButton = { TextButton(onClick = { clearPrompt = false }) { Text("Отмена") } })
    }
}

@Composable
private fun StatCard(label: String, value: String, detail: String, modifier: Modifier) {
    Card(modifier) { Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(label, fontSize = 12.sp, color = MaterialTheme.colorScheme.secondary)
        Text(value, fontSize = 19.sp, fontWeight = FontWeight.SemiBold)
        Text(detail, fontSize = 11.sp, color = MaterialTheme.colorScheme.secondary)
    } }
}

private fun modeLabel(mode: SelectedMode) = when (mode) { SelectedMode.VLESS -> "VLESS"; SelectedMode.TURN -> "VK TURN"; SelectedMode.DIRECT -> "DIRECT" }
private fun phaseLabel(phase: VpnPhase) = when (phase) {
    VpnPhase.DISCONNECTED -> "Отключено"
    VpnPhase.PREPARING -> "Подготовка"
    VpnPhase.BOOTSTRAPPING -> "Получение TURN-доступа"
    VpnPhase.CONNECTING -> "Подключение"
    VpnPhase.CONNECTED -> "Подключено"
    VpnPhase.WAITING_FOR_NETWORK -> "Ожидание сети"
    VpnPhase.RECONNECTING -> "Восстановление"
    VpnPhase.STOPPING -> "Отключение"
    VpnPhase.ERROR -> "Ошибка подключения"
}
private fun bytes(value: Long): String {
    val n = value.coerceAtLeast(0).toDouble()
    return when {
        n >= 1024 * 1024 * 1024 -> "%.2f ГиБ".format(n / (1024 * 1024 * 1024))
        n >= 1024 * 1024 -> "%.1f МиБ".format(n / (1024 * 1024))
        n >= 1024 -> "%.1f КиБ".format(n / 1024)
        else -> "${n.toLong()} Б"
    }
}
