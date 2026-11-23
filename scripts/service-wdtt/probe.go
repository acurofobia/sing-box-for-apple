// Build from upstream/sing-box with the same WireGuard and gVisor tags as the app.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/experimental/libbox"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
	M "github.com/sagernet/sing/common/metadata"
	"github.com/sagernet/sing/service/filemanager"
)

func probe() error {
	var req struct{ Link, URL string }
	if err := json.NewDecoder(io.LimitReader(os.Stdin, 16384)).Decode(&req); err != nil {
		return err
	}
	endpoint, err := url.Parse(req.URL)
	if err != nil || endpoint.Scheme != "https" || endpoint.Hostname() == "" || endpoint.User != nil {
		return errors.New("invalid destination")
	}
	body, ok := strings.CutPrefix(req.Link, "wdtt://")
	parts := strings.SplitN(body, ":", 6)
	if !ok || len(parts) != 6 {
		return errors.New("invalid credential")
	}
	hash := strings.FieldsFunc(parts[5], func(r rune) bool { return r == ',' || r == '#' })
	if len(hash) == 0 {
		return errors.New("missing call")
	}
	dir, err := os.MkdirTemp("", "vipin-probe-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	identity := sha256.Sum256([]byte("health:" + parts[4]))
	proxy := map[string]any{"vk_link": "https://vk.ru/call/join/" + hash[0], "peer_addr": net.JoinHostPort(parts[0], parts[1]), "wrap_a_password": parts[4], "use_wrap_a": true, "num_conns": 1, "device_id": "health-" + hex.EncodeToString(identity[:16])}
	input, err := json.Marshal(map[string]any{"proxy": proxy, "route": map[string]any{"final": "vk-wg"}, "cache_path": dir})
	if err != nil {
		return err
	}
	session, err := libbox.StartVKTurnPrototype(string(input))
	if err != nil {
		return err
	}
	defer libbox.StopVKTurnPrototype(session.ID)
	var raw map[string]json.RawMessage
	if err = json.Unmarshal([]byte(session.Configuration), &raw); err != nil {
		return err
	}
	delete(raw, "inbounds")
	delete(raw, "experimental")
	raw["log"] = json.RawMessage(`{"disabled":true}`)
	data, err := json.Marshal(raw)
	if err != nil {
		return err
	}
	ctx := filemanager.WithDefault(include.Context(context.Background()), dir, dir, os.Getuid(), os.Getgid())
	var opt option.Options
	if err = opt.UnmarshalJSONContext(ctx, data); err != nil {
		return err
	}
	opt.Route.DefaultDomainResolver = &option.DomainResolveOptions{Server: "dns"}
	instance, err := box.New(box.Options{Context: ctx, Options: opt})
	if err != nil {
		return err
	}
	defer instance.Close()
	if err = instance.Start(); err != nil {
		return err
	}
	outbound, ok := instance.Outbound().Outbound("vk-wg")
	if !ok {
		return errors.New("transport unavailable")
	}
	transport := &http.Transport{DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
		dst := M.ParseSocksaddr(address)
		return outbound.DialContext(ctx, network, dst)
	}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 30 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	res, err := client.Get(req.URL)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	result, err := io.ReadAll(io.LimitReader(res.Body, 128))
	if err != nil || res.StatusCode != 200 || strings.TrimSpace(string(result)) != "vipin-service-wdtt-ok" {
		return errors.New("health check failed")
	}
	return nil
}
func main() {
	if probe() != nil {
		os.Exit(1)
	}
}
