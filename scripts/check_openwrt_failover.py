#!/usr/bin/env python3
"""Supervise the opt-in iPhone failover test using an authenticated SSH socket.

The native test exports only endpoint addresses and observations. Temporary nft
sets expire after 180 seconds; a router watchdog and host finally remove the
test table. Existing firewall configuration and acceleration settings stay intact.
"""
import argparse
import ipaddress
import json
from pathlib import Path
import re
import shlex
import signal
import socket
import subprocess
import time
import uuid

GROUP = 'group.ru.acurofobia.singbox.vkprototype'
REMOTE = 'Documents/FailoverAcceptance/'
RUNNER = 'ru.acurofobia.singbox.vkprototype.SFIUITests.xctrunner'


class Supervisor:
    def __init__(self, args):
        self.args = args
        self.output = Path(args.output).resolve()
        self.output.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.peers = {}
        self.initialized = False
        self.events = []
        self.table = 'codex_vipin_' + uuid.uuid4().hex[:8]

    def ssh(self, script, check=True):
        result = subprocess.run(['ssh', '-S', self.args.ssh_socket, '-o', 'BatchMode=yes',
                                 self.args.router, 'sh', '-s'], input=script, text=True,
                                capture_output=True, timeout=20)
        if check and result.returncode:
            raise RuntimeError('Router command failed: ' + result.stderr.strip())
        return result

    def transfer(self, direction, name, telemetry=False):
        local = self.output / name
        command = ['xcrun', 'devicectl', 'device', 'copy', direction, '--device', self.args.device,
                   '--domain-type', 'appGroupDataContainer' if telemetry else 'appDataContainer',
                   '--domain-identifier', GROUP if telemetry else RUNNER,
                   '--timeout', '15']
        if direction == 'from':
            source = 'Library/Caches/FailoverAcceptance/' + name if telemetry else REMOTE + name
            command += ['--source', source, '--destination', str(local)]
        else:
            command += ['--source', str(local), '--destination', REMOTE + name]
        return subprocess.run(command, capture_output=True, text=True, timeout=20)

    def initialize(self, candidates):
        if len(candidates) != 4:
            raise ValueError('Expected exactly four candidates')
        for candidate in candidates:
            tag, host, port = candidate['tag'], candidate['server'], candidate['port']
            if not re.fullmatch(r'[A-Za-z0-9_.-]{1,64}', tag) or not isinstance(port, int) or not 1 <= port <= 65535:
                raise ValueError('Invalid candidate metadata')
            try:
                addresses = {str(ipaddress.ip_address(host))}
            except ValueError:
                addresses = {item[4][0] for item in socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)}
            peers = {(str(ipaddress.ip_address(address)), port) for address in addresses}
            self.peers[tag] = peers
        if self.ssh('nft list table inet ' + self.table, check=False).returncode == 0:
            raise RuntimeError('Temporary table already exists; inspect its ownership before continuing')
        phone = str(ipaddress.IPv4Address(self.args.phone_ip))
        if not re.fullmatch(r'(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}', self.args.phone_mac):
            raise ValueError('Invalid phone MAC')
        rules = '\n'.join([
            f'add table inet {self.table}',
            f'add set inet {self.table} blocked4 {{ type ipv4_addr . inet_service; flags timeout; timeout 180s; }}',
            f'add set inet {self.table} blocked6 {{ type ipv6_addr . inet_service; flags timeout; timeout 180s; }}',
            f'add chain inet {self.table} block {{ type filter hook prerouting priority -310; policy accept; }}',
            f'add rule inet {self.table} block iifname "br-lan" ether saddr {self.args.phone_mac} ip saddr {phone} ip daddr . tcp dport @blocked4 counter drop',
            f'add rule inet {self.table} block iifname "br-lan" ether saddr {self.args.phone_mac} ip6 daddr . tcp dport @blocked6 counter drop',
        ]) + '\n'
        self.ssh("nft -c -f - <<'NFT'\n" + rules + 'NFT\n')
        # Start cleanup before applying any rules. No credentials are stored.
        cleanup = f'nft delete table inet {self.table} 2>/dev/null || true'
        watchdog = f'nohup sh -c {shlex.quote("sleep 900; " + cleanup)} </dev/null >/tmp/codex-vipin-watchdog.log 2>&1 & echo $!'
        self.ssh(watchdog)
        self.initialized = True
        self.ssh("nft -f - <<'NFT'\n" + rules + 'NFT\n')
        self.log('initialized', {'phone': phone, 'candidates': candidates, 'resolved': {
            tag: sorted(peers) for tag, peers in self.peers.items()}})

    def stats(self):
        if not self.initialized:
            return {}
        result = self.ssh('nft -j list table inet ' + self.table)
        data = json.loads(result.stdout)
        packets = 0
        for item in data.get('nftables', []):
            for expr in item.get('rule', {}).get('expr', []):
                packets += expr.get('counter', {}).get('packets', 0)
        return {'dropped_packets': packets}

    def apply(self, request):
        if request['stage'] == 'cleanup':
            self.cleanup()
            return
        if not self.initialized:
            self.initialize(request['candidates'])
        lines = [f'flush set inet {self.table} blocked4', f'flush set inet {self.table} blocked6']
        blocked = set()
        for tag in request['blockedTags']:
            blocked |= self.peers[tag]
        for address, port in sorted(blocked):
            family = ipaddress.ip_address(address).version
            lines.append(f'add element inet {self.table} blocked{family} {{ {address} . {port} timeout 180s }}')
        self.ssh("nft -f - <<'NFT'\n" + '\n'.join(lines) + '\nNFT\n')
        self.log('stage', {'name': request['stage'], 'blocked': request['blockedTags'], **self.stats()})

    def cleanup(self):
        if self.initialized:
            try:
                stats = self.stats()
            except Exception as error:
                stats = {'statistics_error': str(error)}
            self.ssh('nft delete table inet ' + self.table)
            self.initialized = False
            self.log('cleanup', stats)

    def log(self, kind, details):
        event = {'time': time.time(), 'kind': kind, **details}
        self.events.append(event)
        (self.output / 'router-events.json').write_text(json.dumps(self.events, indent=2))
        print(json.dumps(event), flush=True)

    def run(self):
        previous = None
        if self.transfer('from', 'request.json').returncode == 0:
            stale = json.loads((self.output / 'request.json').read_text())
            previous = (stale['run'], stale['sequence'])
        log = (self.output / 'xcode-test.log').open('w')
        process = subprocess.Popen([
            'xcodebuild', 'test-without-building', '-xctestrun', self.args.xctestrun,
            '-destination', 'id=' + self.args.device, '-resultBundlePath', str(self.output / 'test.xcresult')
        ], stdout=log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 840
        try:
            while process.poll() is None:
                if time.monotonic() >= deadline:
                    raise TimeoutError('Hardware test exceeded supervisor deadline')
                if self.transfer('from', 'telemetry.json', telemetry=True).returncode == 0:
                    self.transfer('to', 'telemetry.json')
                if self.transfer('from', 'request.json').returncode == 0:
                    request = json.loads((self.output / 'request.json').read_text())
                    identity = (request['run'], request['sequence'])
                    if identity != previous:
                        reply = {'run': request['run'], 'sequence': request['sequence']}
                        try:
                            self.apply(request)
                        except Exception as error:
                            reply['error'] = str(error)
                            self.log('error', {'message': str(error)})
                        (self.output / 'reply.json').write_text(json.dumps(reply))
                        transferred = self.transfer('to', 'reply.json')
                        if transferred.returncode:
                            raise RuntimeError('Could not acknowledge stage: ' + transferred.stderr)
                        previous = identity
                time.sleep(1)
            self.transfer('from', 'observations.json')
            self.log('test-finished', {'exit_code': process.returncode})
            return process.returncode
        finally:
            try:
                self.cleanup()
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        process.kill()
                log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ssh-socket', required=True)
    parser.add_argument('--router', default='root@192.168.1.1')
    parser.add_argument('--phone-ip', required=True)
    parser.add_argument('--phone-mac', required=True)
    parser.add_argument('--device', required=True)
    parser.add_argument('--xctestrun', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    def interrupted(signum, frame):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, interrupted)
    return Supervisor(args).run()


if __name__ == '__main__':
    raise SystemExit(main())
