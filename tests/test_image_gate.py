# -------------------------------------------------------
#                LOCAL AI IMAGE GATE TESTS
# -------------------------------------------------------
#
# unittest checks for src\image_gate.py against a fake ComfyUI (HTTP and websocket) and a fake
# Ollama, all on 127.0.0.1 ports the system picks. Run them from the repository root with a
# Python 3.12+ that has aiohttp, such as ComfyUI's venv python:
#   <python> -I -B -m unittest discover -s tests -p "test_*.py"
# tests is not a package, so discovery runs without -t (Python 3.11+ refuses a start folder
# without __init__.py below the top level). -I keeps the repository and PYTHON* variables off
# sys.path, so the gate is loaded from its file path; -B writes no __pycache__.

import asyncio
import contextlib
import gzip
import hashlib
import importlib.util
import io
import json
import os
import re
import socket
import sys
import time
import unittest
from pathlib import Path

import aiohttp
from aiohttp import web
from yarl import URL

GATE_PATH = Path(__file__).resolve().parent.parent / 'src' / 'image_gate.py'
IMAGE = os.urandom(3 * 1024 * 1024)
FRAME = os.urandom(200000)
# Above the 1 MiB that aiohttp's server reads into memory at most, so only a streaming gate passes it on.
UPLOAD = os.urandom(5 * 1024 * 1024)
CHAT = {'name': 'local-chat:latest', 'model': 'local-chat:latest', 'size': 8040000000, 'size_vram': 8040000000}
OTHER = {'name': 'llava:7b', 'model': 'llava:7b', 'size': 4500000000, 'size_vram': 4500000000}
LOG_LINE = re.compile(rb'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z [ -~]*')


# Load src\image_gate.py as the module image_gate without running its main.
def load_gate_module():
    spec = importlib.util.spec_from_file_location('image_gate', GATE_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules['image_gate'] = module
    spec.loader.exec_module(module)
    return module


image_gate = load_gate_module()


# Return a socket bound to a free port on 127.0.0.1, and that port.
def free_socket():
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(('127.0.0.1', 0))
    return sock, sock.getsockname()[1]


# Return a port on 127.0.0.1 that nothing listens on.
def closed_port():
    sock, port = free_socket()
    sock.close()
    return port


# Wait up to $seconds until $condition() is true, polling every 50 ms; return its last answer.
async def wait_for(condition, seconds=5):
    deadline = time.monotonic() + seconds
    while not condition() and time.monotonic() < deadline:
        await asyncio.sleep(0.05)
    return condition()


# A ComfyUI stand-in: it echoes every request, records what it received in $events and seen, and
# serves /view, /gzip, /status and a /ws websocket that echoes, closes or drops on request.
class FakeComfyUI:
    # Start with no requests seen; $events is shared with the fake Ollama to record order.
    def __init__(self, events):
        self.events = events
        self.seen = []
        self.ws_seen = {}
        self.ws_close_code = None
        self.ws_done = asyncio.Event()
        self.gzip_body = gzip.compress(json.dumps({'hello': 'x' * 5000}).encode())

    # Return the fake's aiohttp application.
    def make_app(self):
        app = web.Application(client_max_size=64 * 1024 * 1024)
        app.router.add_get('/ws', self.websocket)
        app.router.add_route('*', '/{path:.*}', self.echo)
        return app

    # Record the request and answer by path: an image, a gzip body, an error, a prompt id, or the
    # request body echoed back with headers that name its length. A body cut off is answered 400.
    async def echo(self, request):
        try:
            body = await request.read()
        except ConnectionError:
            return web.Response(status=400)
        path = request.rel_url.path
        self.seen.append({'method': request.method, 'raw': request.raw_path, 'headers': request.headers.copy(), 'body': body})
        if request.method == 'POST' and path in ('/prompt', '/api/prompt'):
            self.events.append(('comfy', path))
            return web.json_response({'prompt_id': 'p%d' % len(self.seen), 'number': len(self.seen), 'node_errors': {}})
        if path == '/view':
            return web.Response(body=IMAGE, content_type='image/png', headers={'X-Content-Type-Options': 'nosniff'})
        if path == '/gzip':
            return web.Response(body=self.gzip_body, headers={'Content-Encoding': 'gzip', 'Content-Type': 'application/json'})
        if path == '/status':
            response = web.json_response({'error': 'no such prompt'}, status=404,
                                         headers={'X-Upstream': 'yes', 'Keep-Alive': 'timeout=5', 'Proxy-Authenticate': 'Basic'})
            response.headers.add('Set-Cookie', 'a=1')
            response.headers.add('Set-Cookie', 'b=2')
            return response
        status = 201 if request.method == 'POST' else 200
        return web.Response(body=body, status=status, headers={'X-Upstream': 'yes', 'X-Echo-Length': str(len(body))})

    # Send a status text and a binary frame, echo text (reversing binary frames), close with 4001 on
    # 'close4001' and drop the connection without a close frame on 'drop'; record the query, Origin
    # and the close code the client sent.
    async def websocket(self, request):
        ws = web.WebSocketResponse(max_msg_size=0)
        await ws.prepare(request)
        self.ws_seen = {'query': request.rel_url.query_string, 'origin': request.headers.get('Origin'),
                        'authorization': request.headers.get('Authorization')}
        await ws.send_str(json.dumps({'type': 'status'}))
        await ws.send_bytes(b'\x00\x00\x00\x01' + FRAME)
        async for message in ws:
            if message.type == aiohttp.WSMsgType.TEXT:
                if message.data == 'close4001':
                    await ws.close(code=4001, message=b'bye')
                    break
                if message.data == 'drop':
                    request.transport.abort()
                    break
                await ws.send_str('echo:' + message.data)
            elif message.type == aiohttp.WSMsgType.BINARY:
                await ws.send_bytes(message.data[::-1])
        self.ws_close_code = ws.close_code
        self.ws_done.set()
        return ws


# An Ollama stand-in for /api/ps and /api/generate: it lists $loaded and, after an unload request,
# drops that model $unload_delay seconds later, unless keep_loaded. It records each call in $events
# and, in ps_log, each /api/ps call's place in $events and whether its answer listed the chat model.
class FakeOllama:
    # Start with the models in $loaded and the default behaviour of Ollama 0.40.11.
    def __init__(self, events, loaded):
        self.events = events
        self.loaded = list(loaded)
        self.unload_delay = 0.2
        self.ps_delay = 0.0
        self.generate_status = 200
        self.keep_loaded = False
        self.active_ps = 0
        self.most_active_ps = 0
        self.ps_log = []

    # Return the fake's aiohttp application.
    def make_app(self):
        app = web.Application()
        app.router.add_get('/api/ps', self.ps)
        app.router.add_post('/api/generate', self.generate)
        return app

    # List the loaded models, after ps_delay, counting how many calls overlap.
    async def ps(self, request):
        index = len(self.events)
        self.events.append(('ollama', 'ps'))
        self.active_ps += 1
        self.most_active_ps = max(self.most_active_ps, self.active_ps)
        try:
            if self.ps_delay:
                await asyncio.sleep(self.ps_delay)
            models = list(self.loaded)
            self.ps_log.append((index, any(m['name'] == CHAT['name'] for m in models)))
            return web.json_response({'models': models})
        finally:
            self.active_ps -= 1

    # Answer like Ollama's unload request and schedule the model's removal.
    async def generate(self, request):
        body = await request.json()
        self.events.append(('ollama', 'generate', body))
        if self.generate_status != 200:
            return web.json_response({'error': "model '%s' not found" % body.get('model')}, status=self.generate_status)
        if body.get('keep_alive') == 0 and not self.keep_loaded:
            asyncio.get_running_loop().call_later(self.unload_delay, self.drop, body.get('model'))
        return web.json_response({'model': body.get('model'), 'done': True, 'done_reason': 'unload'})

    # Remove the model $name from the loaded list.
    def drop(self, name):
        self.loaded = [m for m in self.loaded if m['name'] != name]


# Shared setup: a fake ComfyUI, a fake Ollama with the chat model loaded, a gate in front of them
# and an HTTP client that adds no headers of its own and leaves bodies compressed.
class GateTestCase(unittest.IsolatedAsyncioTestCase):
    # Start the fakes and one gate; each test may start more gates with start_gate.
    async def asyncSetUp(self):
        self.events = []
        self.lines = []
        self.runners = []
        self.comfy = FakeComfyUI(self.events)
        self.comfy_url = await self.serve(self.comfy.make_app())
        self.ollama = FakeOllama(self.events, [CHAT])
        self.ollama_url = await self.serve(self.ollama.make_app())
        self.gate, self.gate_url = await self.start_gate()
        self.http = aiohttp.ClientSession(auto_decompress=False, skip_auto_headers=('Accept', 'Accept-Encoding', 'User-Agent'))

    # Close the client, then every server this test started.
    async def asyncTearDown(self):
        await self.http.close()
        for runner in reversed(self.runners):
            await runner.cleanup()

    # Serve $app on a free 127.0.0.1 port, or on $sock, and return its base URL.
    async def serve(self, app, sock=None):
        if sock is None:
            sock, _ = free_socket()
        runner = web.AppRunner(app, access_log=None)
        await runner.setup()
        await web.SockSite(runner, sock).start()
        self.runners.append(runner)
        return 'http://127.0.0.1:%d' % sock.getsockname()[1]

    # Start a gate with this test's fakes unless other URLs are given, and return it and its URL.
    async def start_gate(self, upstream=None, ollama=None, model='local-chat:latest', unload_timeout=5.0):
        sock, port = free_socket()
        gate = image_gate.Gate(port, upstream or self.comfy_url, ollama or self.ollama_url, model, unload_timeout,
                               log=self.lines.append, poll_seconds=0.05)
        url = await self.serve(gate.make_app(), sock)
        return gate, url

    # POST a prompt the way Open WebUI does and return (status, JSON answer, seconds taken).
    async def post_prompt(self, url=None, path='/prompt', headers=None, body=None):
        started = time.monotonic()
        payload = body if body is not None else {'prompt': {'3': {'class_type': 'KSampler', 'inputs': {}}}, 'client_id': 'c1'}
        async with self.http.post((url or self.gate_url) + path, json=payload, headers=headers or {}) as answer:
            data = await answer.json(content_type=None)
            return answer.status, data, time.monotonic() - started

    # Send $head and the start of $body to the gate over a raw connection, then reset it after
    # $after seconds, reading up to $read bytes of the answer first; returns the bytes read.
    async def abort_request(self, head, body=b'', after=0.0, read=0):
        port = URL(self.gate_url).port
        reader, writer = await asyncio.open_connection('127.0.0.1', port)
        writer.write(head.replace(b'{host}', b'127.0.0.1:%d' % port) + body)
        await writer.drain()
        received = await reader.read(read) if read else b''
        await asyncio.sleep(after)
        writer.transport.abort()
        return received

    # Return the gate's log lines that report a queued prompt.
    def prompt_lines(self):
        return [line for line in self.lines if ' prompt /' in line]


# The gate's own route, which names what it fronts and is never proxied.
class IdentityTests(GateTestCase):
    # GET /local-ai/image-gate answers the service, version, upstream, Ollama and model, and reaches neither fake.
    async def test_identity_names_the_service_upstream_ollama_and_model_and_is_not_proxied(self):
        async with self.http.get(self.gate_url + '/local-ai/image-gate') as answer:
            self.assertEqual(answer.status, 200)
            data = await answer.json()
        self.assertEqual(data['service'], 'local-ai-image-gate')
        self.assertEqual(data['version'], image_gate.VERSION)
        self.assertEqual(data['upstream'], self.comfy_url)
        self.assertEqual(data['ollama'], self.ollama_url)
        self.assertEqual(data['model'], 'local-chat:latest')
        self.assertEqual(self.comfy.seen, [])
        self.assertEqual(self.events, [])

    # A POST to the identity route gets 405 and is not passed on to ComfyUI.
    async def test_identity_refuses_other_methods_without_proxying(self):
        async with self.http.post(self.gate_url + '/local-ai/image-gate', data=b'x') as answer:
            self.assertEqual(answer.status, 405)
        self.assertEqual(self.comfy.seen, [])


# HTTP requests relayed to ComfyUI: paths, headers, bodies, encodings, errors and hang-ups.
class ProxyTests(GateTestCase):
    # A GET keeps its raw path and query and drops hop-by-hop, Origin and Referer headers on the way.
    async def test_get_keeps_path_and_query_exactly_and_drops_hop_by_hop_origin_and_referer(self):
        target = URL(self.gate_url + '/echo/a%20b%2Fc?x=1&y=%2F+z&e=', encoded=True)
        headers = {'X-Keep': '1', 'Authorization': 'Bearer abc', 'Connection': 'X-Drop', 'X-Drop': '1', 'Keep-Alive': 'timeout=5',
                   'Proxy-Authorization': 'Basic eA==', 'TE': 'trailers', 'Origin': self.gate_url, 'Referer': self.gate_url + '/'}
        async with self.http.get(target, headers=headers) as answer:
            self.assertEqual(answer.status, 200)
            self.assertEqual(answer.headers['X-Upstream'], 'yes')
        seen = self.comfy.seen[-1]
        self.assertEqual(seen['method'], 'GET')
        self.assertEqual(seen['raw'], '/echo/a%20b%2Fc?x=1&y=%2F+z&e=')
        self.assertEqual(seen['headers']['Host'], self.comfy_url[len('http://'):])
        self.assertEqual(seen['headers']['X-Keep'], '1')
        self.assertEqual(seen['headers']['Authorization'], 'Bearer abc')
        for name in ('X-Drop', 'Keep-Alive', 'Proxy-Authorization', 'TE', 'Origin', 'Referer', 'Accept-Encoding', 'User-Agent',
                     'Transfer-Encoding', 'Content-Length'):
            self.assertNotIn(name, seen['headers'], name)
        self.assertEqual(self.events, [])

    # A 5 MiB body, above aiohttp's in-memory limit, reaches ComfyUI whole with its length and comes back.
    async def test_post_streams_a_binary_body_with_its_length_and_relays_the_answer(self):
        async with self.http.post(self.gate_url + '/upload/image?overwrite=true', data=io.BytesIO(UPLOAD),
                                  headers={'Content-Type': 'application/octet-stream'}) as answer:
            self.assertEqual(answer.status, 201)
            echoed = await answer.read()
            self.assertEqual(answer.headers['X-Echo-Length'], str(len(UPLOAD)))
        self.assertEqual(hashlib.sha256(echoed).digest(), hashlib.sha256(UPLOAD).digest())
        seen = self.comfy.seen[-1]
        self.assertEqual(seen['body'], UPLOAD)
        self.assertEqual(seen['raw'], '/upload/image?overwrite=true')
        self.assertEqual(seen['headers']['Content-Length'], str(len(UPLOAD)))
        self.assertEqual(seen['headers']['Content-Type'], 'application/octet-stream')
        self.assertNotIn('Transfer-Encoding', seen['headers'])
        self.assertEqual(self.events, [], 'only a prompt unloads the chat model')

    # A chunked 5 MiB body without a length reaches ComfyUI byte for byte.
    async def test_post_streams_a_chunked_body(self):
        chunks = [UPLOAD[i:i + 256 * 1024] for i in range(0, len(UPLOAD), 256 * 1024)]

        # Yield the test chunks, so the client sends them without a length.
        async def produce():
            for chunk in chunks:
                yield chunk

        async with self.http.post(self.gate_url + '/upload/mask', data=produce()) as answer:
            self.assertEqual(answer.status, 201)
        self.assertEqual(self.comfy.seen[-1]['body'], UPLOAD)

    # ComfyUI's status, headers and repeated Set-Cookie lines come back without its hop-by-hop fields.
    async def test_status_headers_and_repeated_cookies_are_relayed_without_hop_by_hop_fields(self):
        async with self.http.get(self.gate_url + '/status') as answer:
            self.assertEqual(answer.status, 404)
            self.assertEqual(await answer.json(), {'error': 'no such prompt'})
            self.assertEqual(answer.headers['X-Upstream'], 'yes')
            self.assertEqual(answer.headers.getall('Set-Cookie'), ['a=1', 'b=2'])
            self.assertNotIn('Keep-Alive', answer.headers)
            self.assertNotIn('Proxy-Authenticate', answer.headers)

    # A gzip body keeps its Content-Encoding and arrives as the compressed bytes ComfyUI sent.
    async def test_content_encoding_passes_through_undecoded(self):
        async with self.http.get(self.gate_url + '/gzip', headers={'Accept-Encoding': 'gzip'}) as answer:
            self.assertEqual(answer.status, 200)
            self.assertEqual(answer.headers['Content-Encoding'], 'gzip')
            raw = await answer.read()
        self.assertEqual(raw, self.comfy.gzip_body)
        self.assertEqual(len(json.loads(gzip.decompress(raw))['hello']), 5000)
        self.assertEqual(self.comfy.seen[-1]['headers']['Accept-Encoding'], 'gzip')

    # A 3 MiB image comes back whole with its length, type and nosniff header.
    async def test_a_large_image_arrives_whole_with_its_length_and_type(self):
        async with self.http.get(self.gate_url + '/view?filename=ComfyUI_temp_00001_.png&subfolder=&type=temp') as answer:
            self.assertEqual(answer.status, 200)
            self.assertEqual(answer.headers['Content-Type'], 'image/png')
            self.assertEqual(answer.headers['Content-Length'], str(len(IMAGE)))
            self.assertEqual(answer.headers['X-Content-Type-Options'], 'nosniff')
            self.assertEqual(await answer.read(), IMAGE)

    # A HEAD answer carries the length but no body, so a GET on the same kept-alive connection still works.
    async def test_head_keeps_the_connection_usable_for_the_next_request(self):
        async with self.http.head(self.gate_url + '/view?filename=a.png') as answer:
            self.assertEqual(answer.status, 200)
            self.assertEqual(answer.headers['Content-Length'], str(len(IMAGE)))
            self.assertEqual(await answer.read(), b'')
        async with self.http.get(self.gate_url + '/view?filename=a.png') as answer:
            self.assertEqual(await answer.read(), IMAGE)
        self.assertEqual([seen['method'] for seen in self.comfy.seen], ['HEAD', 'GET'])

    # An unreachable ComfyUI gives a short 502 for a GET and a prompt, and the prompt's line says so.
    async def test_an_unreachable_comfyui_gives_502_with_a_short_json_body(self):
        _, url = await self.start_gate(upstream='http://127.0.0.1:%d' % closed_port())
        async with self.http.get(url + '/history/p1') as answer:
            self.assertEqual(answer.status, 502)
            data = await answer.json()
        self.assertIn('unreachable', data['error'])
        self.assertLess(len(json.dumps(data)), 300)
        status, _, _ = await self.post_prompt(url)
        self.assertEqual(status, 502)
        self.assertEqual(len(self.prompt_lines()), 1)
        self.assertIn('ComfyUI is unreachable', self.prompt_lines()[0])
        self.assertIn('answered 502', self.prompt_lines()[0])

    # A client that resets mid-download is logged as the client closing, not as ComfyUI breaking off.
    async def test_a_client_that_leaves_mid_download_is_named_in_the_log(self):
        received = await self.abort_request(b'GET /view?filename=a.png HTTP/1.1\r\nHost: {host}\r\n\r\n', read=1000)
        self.assertTrue(received.startswith(b'HTTP/1.1 200'))
        self.assertTrue(await wait_for(lambda: any('closed the connection' in line for line in self.lines)), self.lines)
        self.assertTrue(any('GET /view: the client closed the connection before the answer ended' in line for line in self.lines), self.lines)
        self.assertFalse(any('ComfyUI broke off' in line for line in self.lines), self.lines)

    # A client that resets during its upload is logged as the client closing, not as ComfyUI unreachable.
    async def test_a_client_that_leaves_mid_upload_is_named_in_the_log(self):
        head = b'POST /upload/image HTTP/1.1\r\nHost: {host}\r\nContent-Type: application/octet-stream\r\nContent-Length: %d\r\n\r\n' % len(UPLOAD)
        await self.abort_request(head, UPLOAD[:65536], after=0.3)
        self.assertTrue(await wait_for(lambda: any('/upload/image' in line for line in self.lines)), self.lines)
        line = [line for line in self.lines if '/upload/image' in line][0]
        self.assertIn('the client closed the connection', line)
        self.assertNotIn('unreachable', line)


# The websocket relay in both directions, with close codes.
class WebSocketTests(GateTestCase):
    # Text and binary frames pass both ways, and ComfyUI sees the clientId but no Origin.
    async def test_messages_pass_both_ways_as_text_and_binary_with_the_client_id(self):
        async with self.http.ws_connect(self.gate_url + '/ws?clientId=abc', headers={'Authorization': 'Bearer '}) as ws:
            first = await ws.receive()
            second = await ws.receive()
            self.assertEqual(first.type, aiohttp.WSMsgType.TEXT)
            self.assertEqual(json.loads(first.data), {'type': 'status'})
            self.assertEqual(second.type, aiohttp.WSMsgType.BINARY)
            self.assertEqual(second.data, b'\x00\x00\x00\x01' + FRAME)
            await ws.send_str('hello')
            self.assertEqual((await ws.receive()).data, 'echo:hello')
            await ws.send_bytes(b'\x01\x02\x03')
            reply = await ws.receive()
            self.assertEqual(reply.type, aiohttp.WSMsgType.BINARY)
            self.assertEqual(reply.data, b'\x03\x02\x01')
        self.assertEqual(self.comfy.ws_seen['query'], 'clientId=abc')
        self.assertIsNone(self.comfy.ws_seen['origin'])
        self.assertEqual(self.events, [], 'a websocket never unloads the chat model')

    # ComfyUI's close code 4001 reaches the client unchanged.
    async def test_a_close_from_comfyui_reaches_the_client_with_its_code(self):
        async with self.http.ws_connect(self.gate_url + '/ws?clientId=abc') as ws:
            await ws.receive()
            await ws.receive()
            await ws.send_str('close4001')
            closing = await ws.receive()
            self.assertEqual(closing.type, aiohttp.WSMsgType.CLOSE)
            self.assertEqual(closing.data, 4001)

    # A ComfyUI connection dropped without a close frame closes the client with 1011, as 1006 may not be sent.
    async def test_an_abrupt_comfyui_drop_closes_the_client_with_1011(self):
        async with self.http.ws_connect(self.gate_url + '/ws?clientId=abc') as ws:
            await ws.receive()
            await ws.receive()
            await ws.send_str('drop')
            closing = await asyncio.wait_for(ws.receive(), 5)
            self.assertEqual(closing.type, aiohttp.WSMsgType.CLOSE)
            self.assertEqual(closing.data, 1011)

    # The client's close code 4002 reaches ComfyUI unchanged.
    async def test_a_close_from_the_client_reaches_comfyui_with_its_code(self):
        ws = await self.http.ws_connect(self.gate_url + '/ws?clientId=def')
        await ws.receive()
        await ws.receive()
        await ws.close(code=4002)
        await asyncio.wait_for(self.comfy.ws_done.wait(), 5)
        self.assertEqual(self.comfy.ws_close_code, 4002)

    # An unreachable ComfyUI fails the client's handshake with 502.
    async def test_an_unreachable_comfyui_fails_the_handshake_with_502(self):
        _, url = await self.start_gate(upstream='http://127.0.0.1:%d' % closed_port())
        with self.assertRaises(aiohttp.WSServerHandshakeError) as caught:
            await self.http.ws_connect(url + '/ws?clientId=x')
        self.assertEqual(caught.exception.status, 502)

    # Codes a close frame may not carry map to 1000 (none given) or 1011 (dropped); others pass.
    def test_close_codes_that_may_not_be_sent_are_mapped(self):
        self.assertEqual(image_gate.sendable_close_code(4001), 4001)
        self.assertEqual(image_gate.sendable_close_code(1000), 1000)
        self.assertEqual(image_gate.sendable_close_code(1005), 1000)
        self.assertEqual(image_gate.sendable_close_code(1006), 1011)
        self.assertEqual(image_gate.sendable_close_code(None), 1011)


# The Host, Origin and Sec-Fetch-Site checks that keep web pages and DNS rebinding out.
class RefusalTests(GateTestCase):
    # A Host other than the gate's own address and port gets 403 and reaches nothing.
    async def test_a_foreign_host_is_refused_as_dns_rebinding(self):
        port = URL(self.gate_url).port
        for host in ('evil.example:%d' % port, 'evil.example', '127.0.0.1:%d' % (port + 1), '127.0.0.2:%d' % port):
            async with self.http.get(self.gate_url + '/local-ai/image-gate', headers={'Host': host}) as answer:
                self.assertEqual(answer.status, 403, host)
            async with self.http.post(self.gate_url + '/prompt', json={'prompt': {}}, headers={'Host': host}) as answer:
                self.assertEqual(answer.status, 403, host)
        self.assertEqual(self.comfy.seen, [])
        self.assertEqual(self.events, [])

    # 127.0.0.1 and localhost, in any case, with the gate's port are served.
    async def test_its_own_address_and_localhost_are_accepted(self):
        port = URL(self.gate_url).port
        for host in ('127.0.0.1:%d' % port, 'localhost:%d' % port, 'LOCALHOST:%d' % port):
            async with self.http.get(self.gate_url + '/system_stats', headers={'Host': host}) as answer:
                self.assertEqual(answer.status, 200, host)

    # An HTTP/1.0 request without a Host header gets 403.
    async def test_a_request_without_host_is_refused(self):
        reader, writer = await asyncio.open_connection('127.0.0.1', URL(self.gate_url).port)
        writer.write(b'GET /system_stats HTTP/1.0\r\n\r\n')
        await writer.drain()
        status = await reader.readline()
        writer.close()
        self.assertIn(b' 403 ', status)
        self.assertEqual(self.comfy.seen, [])

    # A foreign Origin gets 403 for a GET, a prompt and a websocket, and unloads nothing.
    async def test_a_web_page_origin_is_refused_for_http_prompts_and_websockets(self):
        for origin in ('http://evil.example', 'null', 'http://127.0.0.1:1'):
            async with self.http.get(self.gate_url + '/object_info', headers={'Origin': origin}) as answer:
                self.assertEqual(answer.status, 403, origin)
            status, _, _ = await self.post_prompt(headers={'Origin': origin})
            self.assertEqual(status, 403, origin)
            with self.assertRaises(aiohttp.WSServerHandshakeError) as caught:
                await self.http.ws_connect(self.gate_url + '/ws?clientId=x', origin=origin)
            self.assertEqual(caught.exception.status, 403)
        self.assertEqual(self.comfy.seen, [])
        self.assertEqual(self.events, [], 'a refused prompt unloads nothing')

    # The gate's own origin, by address or as localhost, is served.
    async def test_its_own_origin_is_accepted(self):
        for origin in (self.gate_url, self.gate_url.replace('127.0.0.1', 'localhost')):
            async with self.http.get(self.gate_url + '/object_info', headers={'Origin': origin}) as answer:
                self.assertEqual(answer.status, 200, origin)

    # Sec-Fetch-Site cross-site gets 403, same-origin is served.
    async def test_a_cross_site_fetch_is_refused(self):
        async with self.http.get(self.gate_url + '/view?filename=a.png', headers={'Sec-Fetch-Site': 'cross-site'}) as answer:
            self.assertEqual(answer.status, 403)
        async with self.http.get(self.gate_url + '/view?filename=a.png', headers={'Sec-Fetch-Site': 'same-origin'}) as answer:
            self.assertEqual(answer.status, 200)

    # Hundreds of refusals write one short line; the next line after a minute counts those left out.
    async def test_refusals_write_one_short_line_a_minute(self):
        long_path = '/' + 'x' * 2000
        for _ in range(300):
            async with self.http.get(self.gate_url + long_path, headers={'Origin': 'http://evil.example'}) as answer:
                self.assertEqual(answer.status, 403)
        refused = [line for line in self.lines if ' refused ' in line]
        self.assertEqual(len(refused), 1, refused)
        self.assertLess(len(refused[0]), 250)
        self.gate.refusal_logged -= image_gate.REFUSAL_LOG_SECONDS + 1
        async with self.http.get(self.gate_url + '/again', headers={'Origin': 'http://evil.example'}) as answer:
            self.assertEqual(answer.status, 403)
        refused = [line for line in self.lines if ' refused ' in line]
        self.assertEqual(len(refused), 2)
        self.assertIn('/again', refused[1])
        self.assertIn('(299 more refused since the last such line)', refused[1])


# The unload of the chat model before a queued prompt, its failures and its order.
class UnloadTests(GateTestCase):
    # A prompt waits for /api/ps, the keep_alive 0 request and the polls until the model is gone, then reaches ComfyUI.
    async def test_a_prompt_waits_for_ps_unload_and_the_poll_before_it_is_forwarded(self):
        body = {'prompt': {'6': {'class_type': 'CLIPTextEncode', 'inputs': {'text': 'a red apple'}}}, 'client_id': 'c1'}
        status, data, _ = await self.post_prompt(body=body)
        self.assertEqual(status, 200)
        self.assertIn('prompt_id', data)
        self.assertEqual(self.events[0], ('ollama', 'ps'))
        self.assertEqual(self.events[1], ('ollama', 'generate', {'model': 'local-chat:latest', 'keep_alive': 0}))
        polls = self.events[2:-1]
        self.assertGreaterEqual(len(polls), 2, 'the model stays listed for a while after the unload request')
        self.assertTrue(all(event == ('ollama', 'ps') for event in polls))
        self.assertEqual(self.events[-1], ('comfy', '/prompt'))
        self.assertEqual(json.loads(self.comfy.seen[-1]['body']), body)
        self.assertEqual(len(self.prompt_lines()), 1)
        self.assertIn('unloaded local-chat:latest in ', self.prompt_lines()[0])
        self.assertIn('ComfyUI answered 200', self.prompt_lines()[0])

    # POST /api/prompt unloads the model as POST /prompt does.
    async def test_api_prompt_unloads_too(self):
        status, _, _ = await self.post_prompt(path='/api/prompt')
        self.assertEqual(status, 200)
        self.assertIn(('ollama', 'generate', {'model': 'local-chat:latest', 'keep_alive': 0}), self.events)
        self.assertEqual(self.events[-1], ('comfy', '/api/prompt'))

    # A GET of /prompt and POSTs to other routes reach ComfyUI without asking Ollama.
    async def test_requests_that_queue_nothing_never_unload(self):
        async with self.http.get(self.gate_url + '/prompt') as answer:
            self.assertEqual(answer.status, 200)
        for path in ('/history', '/queue', '/interrupt', '/prompt/', '/promptx'):
            async with self.http.post(self.gate_url + path, data=b'{}') as answer:
                self.assertEqual(answer.status, 201, path)
        self.assertEqual([e for e in self.events if e[0] == 'ollama'], [])
        self.assertEqual(self.prompt_lines(), [])

    # Without the chat model loaded only /api/ps is asked, and another model is logged with its size_vram but kept.
    async def test_no_unload_when_the_model_is_not_loaded_and_other_models_are_left_alone(self):
        self.ollama.loaded = [OTHER]
        status, _, _ = await self.post_prompt()
        self.assertEqual(status, 200)
        self.assertEqual(self.events, [('ollama', 'ps'), ('comfy', '/prompt')])
        line = self.prompt_lines()[0]
        self.assertIn('local-chat:latest was not loaded', line)
        self.assertIn('left loaded: llava:7b (size_vram 4500000000)', line)
        self.assertNotIn('WARNING', line)

    # The alias matches /api/ps entries with or without ':latest' and in any case, but not another tag.
    async def test_the_model_matches_with_or_without_latest(self):
        gate, url = await self.start_gate(model='local-chat')
        status, _, _ = await self.post_prompt(url)
        self.assertEqual(status, 200)
        self.assertIn(('ollama', 'generate', {'model': 'local-chat:latest', 'keep_alive': 0}), self.events)
        self.assertEqual(image_gate.full_model_name('Local-Chat'), 'local-chat:latest')
        self.assertEqual(image_gate.full_model_name('local-chat:latest'), 'local-chat:latest')
        self.assertEqual(image_gate.full_model_name('hf.co/user/repo:Q6_K'), 'hf.co/user/repo:q6_k')
        self.assertEqual(image_gate.full_model_name('registry:5000/name'), 'registry:5000/name:latest')
        self.assertTrue(gate.is_chat_model({'model': 'LOCAL-CHAT:latest'}))
        self.assertFalse(gate.is_chat_model({'name': 'local-chat:v2'}))

    # With Ollama down the prompt goes on at once with one WARNING line.
    async def test_ollama_down_fails_open_at_once_with_one_warning(self):
        _, url = await self.start_gate(ollama='http://127.0.0.1:%d' % closed_port())
        status, _, seconds = await self.post_prompt(url)
        self.assertEqual(status, 200)
        self.assertLess(seconds, 3)
        self.assertEqual(self.events, [('comfy', '/prompt')])
        lines = self.prompt_lines()
        self.assertEqual(len(lines), 1)
        self.assertIn('WARNING', lines[0])
        self.assertIn('GET /api/ps failed', lines[0])
        self.assertIn('forwarded anyway', lines[0])

    # A slow /api/ps is given up after the unload timeout, and the prompt goes on.
    async def test_a_slow_ollama_fails_open_within_the_timeout(self):
        self.ollama.ps_delay = 1.5
        _, url = await self.start_gate(unload_timeout=0.5)
        status, _, seconds = await self.post_prompt(url)
        self.assertEqual(status, 200)
        self.assertGreaterEqual(seconds, 0.45)
        self.assertLess(seconds, 2)
        self.assertEqual(self.events[-1], ('comfy', '/prompt'))
        self.assertIn('took longer than the 0.5 s unload timeout', self.prompt_lines()[0])
        self.assertIn('WARNING', self.prompt_lines()[0])

    # A model that stays listed is waited for until the timeout, then the prompt goes on.
    async def test_a_model_that_stays_listed_fails_open_after_the_timeout(self):
        self.ollama.keep_loaded = True
        _, url = await self.start_gate(unload_timeout=0.5)
        status, _, seconds = await self.post_prompt(url)
        self.assertEqual(status, 200)
        self.assertLess(seconds, 2)
        self.assertIn('waiting until /api/ps no longer lists local-chat:latest took longer', self.prompt_lines()[0])

    # A 404 to the unload request is logged and the prompt goes on.
    async def test_a_refused_unload_fails_open(self):
        self.ollama.generate_status = 404
        status, _, _ = await self.post_prompt()
        self.assertEqual(status, 200)
        self.assertEqual([e[1] for e in self.events], ['ps', 'generate', '/prompt'])
        self.assertIn('POST /api/generate answered 404', self.prompt_lines()[0])

    # Three prompts at once unload once, ask Ollama one at a time, and reach ComfyUI only after the model is gone.
    async def test_concurrent_prompts_unload_once_one_at_a_time(self):
        self.ollama.ps_delay = 0.05
        results = await asyncio.gather(*(self.post_prompt() for _ in range(3)))
        self.assertEqual([r[0] for r in results], [200, 200, 200])
        self.assertEqual(len([e for e in self.events if e[1] == 'generate']), 1)
        self.assertEqual(self.ollama.most_active_ps, 1, 'the lock lets one unload step ask Ollama at a time')
        comfy = [i for i, event in enumerate(self.events) if event[0] == 'comfy']
        self.assertEqual(len(comfy), 3)
        last_listed = max(index for index, listed in self.ollama.ps_log if listed)
        self.assertGreater(min(comfy), last_listed, 'no prompt reaches ComfyUI while /api/ps still lists the model')
        lines = self.prompt_lines()
        self.assertEqual(len(lines), 3)
        self.assertEqual(len([line for line in lines if 'unloaded local-chat:latest' in line]), 1)
        self.assertEqual(len([line for line in lines if 'was not loaded' in line]), 2)

    # A client that leaves while /api/ps answers slowly gets no unload and no forward.
    async def test_a_client_that_leaves_before_the_unload_gets_neither_unload_nor_forward(self):
        self.ollama.ps_delay = 0.6
        body = b'{"prompt": {}, "client_id": "c"}'
        head = b'POST /prompt HTTP/1.1\r\nHost: {host}\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n' % len(body)
        await self.abort_request(head, body, after=0.2)
        self.assertTrue(await wait_for(lambda: self.prompt_lines()), self.lines)
        self.assertNotIn('generate', [event[1] for event in self.events])
        self.assertNotIn('comfy', [event[0] for event in self.events])
        line = self.prompt_lines()[0]
        self.assertIn('local-chat:latest was not unloaded, as the client had closed the connection', line)
        self.assertIn('the prompt was not forwarded', line)

    # A client that leaves during a slow unload is not forwarded once the unload ends.
    async def test_a_client_that_leaves_during_the_unload_is_not_forwarded(self):
        self.ollama.unload_delay = 1.0
        body = b'{"prompt": {}, "client_id": "c"}'
        head = b'POST /prompt HTTP/1.1\r\nHost: {host}\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n' % len(body)
        await self.abort_request(head, body, after=0.3)
        self.assertTrue(await wait_for(lambda: self.prompt_lines()), self.lines)
        self.assertIn('generate', [event[1] for event in self.events])
        self.assertNotIn('comfy', [event[0] for event in self.events])
        line = self.prompt_lines()[0]
        self.assertIn('unloaded local-chat:latest in ', line)
        self.assertIn('the client closed the connection, so the prompt was not forwarded', line)

    # Prompt text, the client id, the query, the Bearer token and cookies never reach the log.
    async def test_the_log_holds_no_prompt_text_body_query_or_authorization(self):
        body = {'prompt': {'6': {'inputs': {'text': 'SECRET-PROMPT-TEXT'}}}, 'client_id': 'SECRET-CLIENT'}
        status, _, _ = await self.post_prompt(path='/prompt?token=SECRET-QUERY', body=body,
                                              headers={'Authorization': 'Bearer SECRET-TOKEN', 'Cookie': 'SECRET-COOKIE'})
        self.assertEqual(status, 200)
        text = '\n'.join(self.lines)
        for secret in ('SECRET-PROMPT-TEXT', 'SECRET-CLIENT', 'SECRET-QUERY', 'SECRET-TOKEN', 'SECRET-COOKIE'):
            self.assertNotIn(secret, text)
        self.assertEqual(len(self.prompt_lines()), 1)
        self.assertTrue(all(line.isascii() for line in self.lines))


# The command line the launcher passes.
class ArgumentTests(unittest.TestCase):
    # Return the options parse_arguments gives for $argv, or None when it rejects them, with
    # argparse's message kept off the test output.
    def parse(self, *argv):
        with contextlib.redirect_stderr(io.StringIO()):
            try:
                return image_gate.parse_arguments(list(argv))
            except SystemExit:
                return None

    # Loopback URLs lose their trailing '/', and the unload timeout defaults to 30 s.
    def test_loopback_urls_are_accepted_and_trimmed(self):
        options = self.parse('--port', '8190', '--upstream', 'http://127.0.0.1:8188/', '--ollama', 'http://localhost:11434/',
                             '--model', 'local-chat:latest', '--unload-timeout', '12.5')
        self.assertEqual(options.port, 8190)
        self.assertEqual(options.upstream, 'http://127.0.0.1:8188')
        self.assertEqual(options.ollama, 'http://localhost:11434')
        self.assertEqual(options.unload_timeout, 12.5)
        options = self.parse('--port', '8190', '--upstream', 'http://127.0.0.1:8188', '--ollama', 'http://[::1]:11434',
                             '--model', 'local-chat:latest')
        self.assertEqual(options.unload_timeout, 30.0)

    # Other hosts, paths, queries, ports, model names, timeouts and abbreviated options are rejected.
    def test_anything_but_loopback_and_valid_values_is_rejected(self):
        good = ['--port', '8190', '--upstream', 'http://127.0.0.1:8188', '--ollama', 'http://127.0.0.1:11434', '--model', 'local-chat:latest',
                '--unload-timeout', '30']
        self.assertIsNotNone(self.parse(*good))
        for key, value in (('--upstream', 'http://192.0.2.5:8188'), ('--upstream', 'http://127.0.0.1:8188/api'),
                           ('--upstream', 'ftp://127.0.0.1:8188'), ('--ollama', 'http://ollama.example:11434'),
                           ('--ollama', 'http://127.0.0.1:11434?x=1'), ('--port', '0'), ('--port', '70000'),
                           ('--model', 'local chat'), ('--unload-timeout', '0'), ('--unload-timeout', 'nan')):
            argv = list(good)
            argv[argv.index(key) + 1] = value
            self.assertIsNone(self.parse(*argv), f'{key} {value}')
        self.assertIsNone(self.parse('--port', '8190', '--upst', 'http://127.0.0.1:8188', '--ollama', 'http://127.0.0.1:11434',
                                     '--model', 'x'), 'abbreviations are refused')


# The script run as the launcher runs it, in its own process.
class ProcessTests(unittest.IsolatedAsyncioTestCase):
    # Run the gate as the launcher does, python -I -B with the script path, and return the process.
    async def run_gate(self, port):
        return await asyncio.create_subprocess_exec(
            sys.executable, '-I', '-B', str(GATE_PATH), '--port', str(port), '--upstream', 'http://127.0.0.1:%d' % closed_port(),
            '--ollama', 'http://127.0.0.1:%d' % closed_port(), '--model', 'local-chat:latest',
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE)

    # Return the identity the gate on $port answers within 10 s, or None.
    async def identity(self, port):
        async with aiohttp.ClientSession() as http:
            for _ in range(100):
                try:
                    async with http.get('http://127.0.0.1:%d/local-ai/image-gate' % port) as answer:
                        return await answer.json()
                except aiohttp.ClientConnectionError:
                    await asyncio.sleep(0.1)
        return None

    # The script serves its identity on 127.0.0.1 and logs its start line.
    async def test_the_script_serves_its_identity_on_127_0_0_1(self):
        port = closed_port()
        process = await self.run_gate(port)
        try:
            data = await self.identity(port)
            self.assertIsNotNone(data, 'the gate did not answer within 10 s')
            self.assertEqual(data['service'], 'local-ai-image-gate')
        finally:
            process.kill()
            _, err = await process.communicate()
        self.assertIn(b'image gate %s on 127.0.0.1:%d' % (image_gate.VERSION.encode(), port), err)

    # A port another program holds ends the script with code 1 and one line saying so.
    async def test_a_port_in_use_ends_the_script_with_code_1(self):
        holder, port = free_socket()
        holder.listen()
        try:
            process = await self.run_gate(port)
            _, err = await asyncio.wait_for(process.communicate(), 30)
        finally:
            holder.close()
        self.assertEqual(process.returncode, 1)
        self.assertIn(b'cannot listen on 127.0.0.1:%d' % port, err)

    # Malformed requests make aiohttp log one line each, without the request's query or header bytes.
    async def test_aiohttp_errors_reach_the_log_as_one_line_without_request_data(self):
        port = closed_port()
        process = await self.run_gate(port)
        try:
            self.assertIsNotNone(await self.identity(port), 'the gate did not answer within 10 s')
            for request in (b'GET /x HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nAuthorization: Bearer SECRET-TOKEN\x01x\r\n\r\n' % port,
                            b'GET /x?SECRET-QUERY\xff HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n' % port):
                reader, writer = await asyncio.open_connection('127.0.0.1', port)
                writer.write(request)
                await writer.drain()
                self.assertIn(b' 400 ', await asyncio.wait_for(reader.readline(), 5))
                writer.close()
            await asyncio.sleep(0.3)
        finally:
            process.kill()
            _, err = await process.communicate()
        self.assertNotIn(b'SECRET', err)
        self.assertIn(b'aiohttp.server ERROR: ', err)
        lines = [line for line in err.splitlines() if line]
        self.assertGreaterEqual(len(lines), 3)
        for line in lines:
            self.assertIsNotNone(LOG_LINE.fullmatch(line), line)


if __name__ == '__main__':
    unittest.main()
