"""Exercise actual native stream framing, parser recovery and shutdown, without SteamVR."""
import json
import subprocess
import sys

actor_id = 'driver@00000000-0000-0000-0000-000000000001'
def message(typ, payload=None, to=actor_id):
    return {'kind': 'message', 'data': {'address': {'fm': 'caller@x', 'to': to}, 'type': typ, 'payload': payload}}
packets = [
    message('INIT', {'actorId': actor_id, 'callbackKey': 'transport-test'}, 'WORKER'),
    message('ECHO:1', {'text': '犬🐾', 'data': [True, None, 1.25]}),
    message('PING:wrong', to='other@x'),
    message('PING:2'),
    message('SHUTDOWN_AND_CLOSE:3'),
]
wire = b'{bad json\n' + b'x' * 20000 + b'\n'
wire += b''.join((json.dumps(p, ensure_ascii=False) + '\n').encode() for p in packets)
result = subprocess.run([sys.argv[1]], input=wire, capture_output=True, timeout=5, check=True)
rows = [json.loads(line) for line in result.stdout.splitlines()]
assert len(rows) == 8, rows
assert rows[0]['kind'] == 'ready'
assert rows[1]['kind'] == rows[2]['kind'] == 'messageerror'
assert rows[3]['data']['type'] == 'LOADED'
assert rows[4]['data']['payload']['text'] == '犬🐾'
assert rows[5]['kind'] == 'messageerror'
assert rows[6]['data']['type'] == 'PING:2'
assert rows[7]['data']['payload'] is True
print('PASS native stream: coalesced/split reads, malformed/oversized/wrong-target recovery, Unicode, shutdown')
