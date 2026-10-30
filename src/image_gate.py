# -------------------------------------------------------
#                  LOCAL AI IMAGE GATE
# -------------------------------------------------------
#
# A loopback reverse proxy in front of ComfyUI. Before it forwards a request that queues a
# ComfyUI prompt (POST /prompt or /api/prompt), it unloads the chat model from Ollama and waits
# until /api/ps no longer lists it, so ComfyUI has the GPU to itself. Any Ollama error or timeout
# only logs a warning, and the prompt is forwarded anyway. Every other request, websockets
# included, is relayed unchanged. Open WebUI's COMFYUI_BASE_URL points here while
# Images.UnloadChat is on.
#
# The launcher runs it with ComfyUI's venv python, which has aiohttp:
#   python -I -B image_gate.py --port 8190 --upstream http://127.0.0.1:8188
#       --ollama http://127.0.0.1:11434 --model local-chat:latest --unload-timeout 30
# -I keeps PYTHON* variables, the working folder and this script's folder off sys.path, so it
# imports only the standard library, aiohttp and yarl, which aiohttp installs. It reads nothing
# but its arguments and talks only to the loopback addresses they name. It logs to stderr one
# ASCII line per event: a start line, one line per queued prompt, refusals (at most one line a
# minute), connection errors and aiohttp's own errors by their exception class, never prompt
# text, bodies, queries or headers.

import argparse
import asyncio
import dataclasses
import ipaddress
import logging
import re
import sys
import time
from urllib.parse import urlsplit

from aiohttp import ClientError, ClientSession, ClientTimeout, DummyCookieJar, WSMsgType, hdrs, web
from yarl import URL

SERVICE = 'local-ai-image-gate'
VERSION = '1.0.0'
IDENTITY_PATH = '/local-ai/image-gate'
# The only routes that put work on ComfyUI v0.42.5's queue: post_prompt, served with and without /api.
QUEUE_PATHS = frozenset({'/prompt', '/api/prompt'})
# RFC 9110 hop-by-hop fields, which belong to one connection only.
HOP_BY_HOP = frozenset({'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization', 'proxy-connection', 'te',
                        'trailer', 'transfer-encoding', 'upgrade'})
# Also dropped from requests: Host, which aiohttp sets to the upstream's; Origin and Referer, which
# name this gate rather than ComfyUI; and Expect, which aiohttp's server has already answered.
REQUEST_DROPPED = HOP_BY_HOP | {'host', 'origin', 'referer', 'expect'}
# Also dropped from websocket handshakes: the fields aiohttp's client writes itself.
WEBSOCKET_DROPPED = REQUEST_DROPPED | {'sec-websocket-key', 'sec-websocket-version', 'sec-websocket-extensions',
                                       'sec-websocket-protocol', 'sec-websocket-accept'}
# Close codes RFC 6455 lets a close frame carry.
SENDABLE_CLOSE_CODES = frozenset({1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 1012, 1013, 1014} | set(range(3000, 5000)))
# Ollama 0.40.11 drops an idle model from /api/ps 0.24 to 0.37 s after the unload request.
POLL_SECONDS = 0.1
OLLAMA_CALL_SECONDS = 5
CONNECT_SECONDS = 5
# A web page can send refused requests without end; the log gets one line for them per this many seconds.
REFUSAL_LOG_SECONDS = 60
# The most characters of a request path or a library message that a log line holds.
LOGGED_CHARS = 80


# Raised when Ollama answers with an unexpected status or body; the message names the request.
class OllamaError(Exception):
    pass


# What the unload step before one prompt found: result 'unloaded' or 'not loaded', or a problem
# text when it failed; the other loaded models as (name, size_vram); and the time it took.
@dataclasses.dataclass
class UnloadReport:
    started: float
    stage: str = 'waiting for the unload of an earlier prompt'
    result: str = ''
    problem: str = ''
    others: list = dataclasses.field(default_factory=list)
    elapsed_ms: int = 0


# Return $text with every character outside printable ASCII written as a backslash escape, so a
# log line stays one ASCII line whatever a model name holds.
def ascii_text(text):
    return ''.join(c if ' ' <= c <= '~' else c.encode('unicode_escape').decode('ascii') for c in str(text))


# Return $name with ':latest' added when it has no tag, in lowercase, the form in which /api/ps
# names compare.
def full_model_name(name):
    _, colon, tag = name.rpartition(':')
    if not colon or '/' in tag:
        name += ':latest'
    return name.lower()


# Return the close code to send on after a peer closed with $code: the code itself when RFC 6455
# allows it in a close frame, 1000 when there was none (0, 1005), else 1011, as for 1006 after a
# dropped connection.
def sendable_close_code(code):
    if code in SENDABLE_CLOSE_CODES:
        return code
    if code in (0, 1005):
        return 1000
    return 1011


# Return the (name, value) pairs of the multidict $headers in order, without names in $dropped
# (lowercase) or named by a Connection header; repeated fields such as Set-Cookie stay repeated.
def filter_headers(headers, dropped):
    named = {token.strip().lower() for value in headers.getall(hdrs.CONNECTION, ()) for token in value.split(',')}
    return [(name, value) for name, value in headers.items() if name.lower() not in dropped and name.lower() not in named]


# Return a short reason for $error that holds no request data: the message of an OllamaError,
# else the exception's class name.
def describe(error):
    if isinstance(error, OllamaError):
        return str(error)
    return type(error).__name__


# Return the request path $path cut to LOGGED_CHARS characters, for a log line.
def short_path(path):
    return path if len(path) <= LOGGED_CHARS else path[:LOGGED_CHARS] + '...'


# Return True when the client that sent $request has closed its connection; aiohttp drops the
# transport then, and the handler goes on running.
def client_gone(request):
    transport = request.transport
    return transport is None or transport.is_closing()


# A logging handler for the aiohttp and asyncio loggers: each record becomes one gate log line with
# the logger, the level and the exception's class, or else the message's fixed text cut short,
# never the arguments or traceback, which can hold request lines and header bytes.
class OneLineLogHandler(logging.Handler):
    # Pass records of WARNING and above to $gate's log, which adds the time.
    def __init__(self, gate):
        super().__init__(logging.WARNING)
        self.gate = gate

    # Log $record as one line that holds no request data.
    def emit(self, record):
        if record.exc_info and record.exc_info[1] is not None:
            what = type(record.exc_info[1]).__name__
        else:
            what = str(record.msg).split('\n', 1)[0][:LOGGED_CHARS]
        self.gate.log(f'{record.name} {record.levelname}: {what}')


# Return $url without a trailing '/' when it is http or https on a loopback host (localhost,
# 127.0.0.0/8 or ::1) with no user, query or fragment, and with no path when $bare; raise
# argparse.ArgumentTypeError otherwise.
def loopback_url(url, bare=False):
    parts = urlsplit(url)
    try:
        parts.port
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"'{url}' has an invalid port: {error}") from None
    host = parts.hostname
    if parts.scheme not in ('http', 'https') or not host or parts.username or parts.password or parts.query or parts.fragment:
        raise argparse.ArgumentTypeError(f"'{url}' must be an http or https URL with a host and nothing after the path")
    if bare and parts.path not in ('', '/'):
        raise argparse.ArgumentTypeError(f"'{url}' must not have a path")
    if host != 'localhost':
        try:
            loopback = ipaddress.ip_address(host).is_loopback
        except ValueError:
            loopback = False
        if not loopback:
            raise argparse.ArgumentTypeError(f"'{url}' is not on a loopback address; the gate talks to this PC only")
    return url.rstrip('/')


# Return the ComfyUI base URL $url as loopback_url checks it, without a path.
def upstream_url(url):
    return loopback_url(url, bare=True)


# Return $text as a TCP port number from 1 to 65535, or raise argparse.ArgumentTypeError.
def port_number(text):
    if not re.fullmatch(r'[0-9]{1,5}', text) or not 1 <= int(text) <= 65535:
        raise argparse.ArgumentTypeError(f"'{text}' is not a port from 1 to 65535")
    return int(text)


# Return $text as seconds above 0 and at most 3600, or raise argparse.ArgumentTypeError.
def timeout_seconds(text):
    try:
        value = float(text)
    except ValueError:
        value = 0.0
    if not 0 < value <= 3600:
        raise argparse.ArgumentTypeError(f"'{text}' is not a number of seconds above 0 and at most 3600")
    return value


# Return $text when it can be an Ollama model name (letters, digits and ._:/-), or raise
# argparse.ArgumentTypeError.
def model_name(text):
    if not re.fullmatch(r'[A-Za-z0-9._:/-]+', text):
        raise argparse.ArgumentTypeError(f"'{text}' is not an Ollama model name")
    return text


# Return the parsed command line $argv (sys.argv[1:] when None); argparse prints the problem and
# exits with code 2 for a missing or invalid option.
def parse_arguments(argv=None):
    parser = argparse.ArgumentParser(prog='image_gate.py', allow_abbrev=False,
                                     description='Loopback proxy in front of ComfyUI that unloads the chat model from Ollama before each prompt.')
    parser.add_argument('--port', type=port_number, required=True, help='port on 127.0.0.1 to listen on')
    parser.add_argument('--upstream', type=upstream_url, required=True, help='ComfyUI base URL, such as http://127.0.0.1:8188')
    parser.add_argument('--ollama', type=loopback_url, required=True, help='Ollama base URL, such as http://127.0.0.1:11434')
    parser.add_argument('--model', type=model_name, required=True, help='chat model as /api/ps lists it, such as local-chat:latest')
    parser.add_argument('--unload-timeout', type=timeout_seconds, default=30.0, help='seconds to wait for the unload (default 30)')
    return parser.parse_args(argv)


# Write $line to stderr and flush it, so a redirected log is current.
def write_stderr(line):
    print(line, file=sys.stderr, flush=True)


# One gate: its settings, the lock that serialises unloads and, while its app runs, the client
# sessions to ComfyUI and Ollama.
class Gate:
    # Hold one gate's settings: its own $port, ComfyUI's $upstream and Ollama's $ollama base URLs, the
    # chat $model and $unload_timeout in seconds. $log receives each finished log line. No I/O happens
    # until the app from make_app starts.
    def __init__(self, port, upstream, ollama, model, unload_timeout, log=write_stderr, poll_seconds=POLL_SECONDS):
        self.port = port
        self.upstream = upstream.rstrip('/')
        self.ollama = ollama.rstrip('/')
        self.model = model
        self.wanted = full_model_name(model)
        self.unload_timeout = unload_timeout
        self.poll_seconds = poll_seconds
        self.sink = log
        self.hosts = {f'127.0.0.1:{port}', f'localhost:{port}'}
        self.origins = {f'http://127.0.0.1:{port}', f'http://localhost:{port}'}
        self.lock = asyncio.Lock()
        self.comfy = None
        self.ollama_http = None
        self.refused = 0
        self.refusal_logged = None

    # Pass one log line, prefixed with the UTC time and kept to printable ASCII, to the sink.
    def log(self, text):
        self.sink(time.strftime('%Y-%m-%dT%H:%M:%SZ ', time.gmtime()) + ascii_text(text))

    # Log the refusal $refusal of $request: the first one, then at most one line per REFUSAL_LOG_SECONDS,
    # which counts the refusals left out since the line before, so a page that keeps sending requests
    # cannot fill the disk.
    def log_refusal(self, request, refusal):
        now = time.monotonic()
        if self.refusal_logged is not None and now - self.refusal_logged < REFUSAL_LOG_SECONDS:
            self.refused += 1
            return
        more = f' ({self.refused} more refused since the last such line)' if self.refused else ''
        self.log(f'refused {request.method[:16]} {short_path(request.rel_url.path)}: {refusal}{more}')
        self.refused = 0
        self.refusal_logged = now

    # Return the aiohttp application: every method and path goes to dispatch, and the client
    # sessions open and close with it.
    def make_app(self):
        app = web.Application()
        app.cleanup_ctx.append(self.sessions)
        app.router.add_route('*', '/{path:.*}', self.dispatch)
        return app

    # Open the ComfyUI and Ollama client sessions while the app runs (an aiohttp cleanup context).
    # Neither keeps cookies or reads proxy settings; the ComfyUI one adds no header of its own and
    # leaves bodies compressed.
    async def sessions(self, app):
        self.comfy = ClientSession(auto_decompress=False, cookie_jar=DummyCookieJar(), trust_env=False,
                                   timeout=ClientTimeout(total=None, sock_connect=CONNECT_SECONDS),
                                   skip_auto_headers=(hdrs.ACCEPT, hdrs.ACCEPT_ENCODING, hdrs.USER_AGENT, hdrs.CONTENT_TYPE))
        self.ollama_http = ClientSession(cookie_jar=DummyCookieJar(), trust_env=False, timeout=ClientTimeout(total=OLLAMA_CALL_SECONDS))
        try:
            yield
        finally:
            await self.comfy.close()
            await self.ollama_http.close()

    # Return what this gate answers at its identity route.
    def identity(self):
        return {'service': SERVICE, 'version': VERSION, 'upstream': self.upstream, 'ollama': self.ollama, 'model': self.model,
                'unload_timeout': self.unload_timeout}

    # Return why $request must be refused, or '' to serve it: a Host other than this gate's own
    # loopback address and port (DNS rebinding), an Origin other than its own (a web page), or a
    # browser's cross-site fetch. Open WebUI's backend sends neither Origin nor Sec-Fetch-Site.
    def refusal(self, request):
        hosts = request.headers.getall(hdrs.HOST, ())
        if len(hosts) != 1 or hosts[0].lower() not in self.hosts:
            return f'Host must be 127.0.0.1:{self.port} or localhost:{self.port}'
        if any(origin.lower() not in self.origins for origin in request.headers.getall(hdrs.ORIGIN, ())):
            return 'requests from other web pages are refused'
        if request.headers.get('Sec-Fetch-Site', '').lower() == 'cross-site':
            return 'cross-site requests are refused'
        return ''

    # Answer one request: refuse it with 403, answer the identity route, relay a websocket, or
    # proxy it to ComfyUI with path and query exactly as sent, unloading the chat model first when
    # it queues a prompt; a prompt whose client has gone by then is not forwarded.
    async def dispatch(self, request):
        refusal = self.refusal(request)
        if refusal:
            self.log_refusal(request, refusal)
            return web.json_response({'error': refusal}, status=403)
        if request.rel_url.path == IDENTITY_PATH:
            if request.method not in (hdrs.METH_GET, hdrs.METH_HEAD):
                return web.json_response({'error': 'only GET'}, status=405, headers={hdrs.ALLOW: 'GET, HEAD'})
            return web.json_response(self.identity(), headers={hdrs.CACHE_CONTROL: 'no-store'})
        path_qs = request.rel_url.raw_path_qs
        if not path_qs.startswith('/'):
            return web.json_response({'error': 'the request target must be a path'}, status=400)
        target = URL(self.upstream + path_qs, encoded=True)
        if request.method == hdrs.METH_GET and request.headers.get(hdrs.UPGRADE, '').lower() == 'websocket':
            return await self.relay_websocket(request, target)
        report = None
        if request.method == hdrs.METH_POST and target.path in QUEUE_PATHS:
            report = await self.unload_chat(lambda: client_gone(request))
            if client_gone(request):
                self.log_prompt(report, target.path, 'the client closed the connection, so the prompt was not forwarded')
                return web.json_response({'error': 'the client closed the connection'}, status=400)
        return await self.proxy(request, target, report)

    # Forward $request to $target and stream ComfyUI's answer back with its status, headers and
    # bytes; an unreachable ComfyUI gives 502 with a short JSON body. Logs which side broke off, and
    # with an unload $report the prompt's line once the status is known.
    async def proxy(self, request, target, report):
        where = f'{request.method} {short_path(target.path)}'
        body = request.content if request.body_exists else None
        try:
            answer = await self.comfy.request(request.method, target, headers=filter_headers(request.headers, REQUEST_DROPPED),
                                              data=body, allow_redirects=False)
        except (ClientError, ConnectionError) as error:
            # An aborted upload fails the request too, through its body.
            if client_gone(request):
                outcome = 'the client closed the connection before ComfyUI answered'
            else:
                outcome = f'ComfyUI is unreachable ({describe(error)}), answered 502'
            if report:
                self.log_prompt(report, target.path, outcome)
            else:
                self.log(f'{where}: {outcome}')
            return web.json_response({'error': f'ComfyUI at {self.upstream} is unreachable: {describe(error)}'}, status=502)
        async with answer:
            if report:
                self.log_prompt(report, target.path, f'ComfyUI answered {answer.status}')
            response = web.StreamResponse(status=answer.status, reason=answer.reason, headers=filter_headers(answer.headers, HOP_BY_HOP))
            try:
                await response.prepare(request)
            except ConnectionError:
                self.log(f'{where}: the client closed the connection before the answer started')
                return response
            while True:
                try:
                    chunk = await answer.content.readany()
                except (ClientError, ConnectionError) as error:
                    # Closing the client's connection tells it the body is incomplete.
                    self.log(f'{where}: ComfyUI broke off its answer ({describe(error)})')
                    if request.transport is not None:
                        request.transport.abort()
                    return response
                if not chunk:
                    break
                try:
                    await response.write(chunk)
                except ConnectionError:
                    self.log(f'{where}: the client closed the connection before the answer ended')
                    return response
            try:
                await response.write_eof()
            except ConnectionError:
                pass
        return response

    # Relay a websocket: connect to ComfyUI first, at $target with the same path and query (its
    # clientId), so no message ComfyUI sends that client is lost, else answer 502. Then pump text
    # and binary messages both ways until either side closes, closing the other with that code.
    async def relay_websocket(self, request, target):
        if not web.WebSocketResponse().can_prepare(request).ok:
            return web.json_response({'error': 'not a valid websocket handshake'}, status=400)
        protocols = [p.strip() for value in request.headers.getall(hdrs.SEC_WEBSOCKET_PROTOCOL, ()) for p in value.split(',') if p.strip()]
        scheme = 'wss' if target.scheme == 'https' else 'ws'
        try:
            upstream = await self.comfy.ws_connect(target.with_scheme(scheme), headers=filter_headers(request.headers, WEBSOCKET_DROPPED),
                                                   protocols=protocols, max_msg_size=0)
        except ClientError as error:
            self.log(f'websocket {short_path(target.path)}: ComfyUI refused or is unreachable ({describe(error)}), answered 502')
            return web.json_response({'error': f'ComfyUI at {self.upstream} did not accept the websocket: {describe(error)}'}, status=502)
        client = web.WebSocketResponse(protocols=(upstream.protocol,) if upstream.protocol else (), max_msg_size=0)
        try:
            await client.prepare(request)
        except BaseException:
            await upstream.close()
            raise
        try:
            from_comfy = asyncio.ensure_future(self.pump(upstream, client))
            from_client = asyncio.ensure_future(self.pump(client, upstream))
            done, pending = await asyncio.wait({from_comfy, from_client}, return_when=asyncio.FIRST_COMPLETED)
            for task in pending:
                task.cancel()
            await asyncio.gather(*pending, return_exceptions=True)
            if from_comfy in done:
                await client.close(code=sendable_close_code(upstream.close_code))
            else:
                await upstream.close(code=sendable_close_code(client.close_code))
        finally:
            await upstream.close()
            await client.close()
        return client

    # Copy text and binary messages from websocket $source to $target until $source closes or
    # fails, or $target can no longer be written to.
    @staticmethod
    async def pump(source, target):
        try:
            async for message in source:
                if message.type == WSMsgType.TEXT:
                    await target.send_str(message.data)
                elif message.type == WSMsgType.BINARY:
                    await target.send_bytes(message.data)
                else:
                    break
        except (ConnectionError, ClientError, RuntimeError):
            pass

    # Before a prompt: under one lock, ask /api/ps; when it lists the chat model, ask /api/generate to
    # unload it (keep_alive 0) and poll /api/ps until it is gone, skipping both once $gone() says the
    # client left. Ends within unload_timeout, lock wait included; failures set the report's problem.
    async def unload_chat(self, gone=lambda: False):
        report = UnloadReport(started=time.monotonic())
        deadline = None
        try:
            async with asyncio.timeout(self.unload_timeout) as deadline:
                async with self.lock:
                    await self.unload_under_lock(report, gone)
        except TimeoutError:
            if deadline is not None and deadline.expired():
                report.problem = f'{report.stage} took longer than the {self.unload_timeout:g} s unload timeout'
            else:
                report.problem = f'{report.stage}: Ollama did not answer within {OLLAMA_CALL_SECONDS} s'
        except (ClientError, OSError, ValueError, OllamaError) as error:
            report.problem = f'{report.stage} failed: {describe(error)}'
        report.elapsed_ms = round((time.monotonic() - report.started) * 1000)
        return report

    # The unload step proper, run under the lock; records its progress in $report, sets the result
    # 'skipped' when $gone() is true before a request to Ollama, and raises on any Ollama failure.
    async def unload_under_lock(self, report, gone):
        if gone():
            report.result = 'skipped'
            return
        report.stage = 'GET /api/ps'
        models = await self.loaded_models()
        report.others = [(str(m.get('name') or m.get('model')), m.get('size_vram')) for m in models if not self.is_chat_model(m)]
        mine = [m for m in models if self.is_chat_model(m)]
        if not mine:
            report.result = 'not loaded'
            return
        # A prompt nobody waits for would cost the next chat its reload for nothing.
        if gone():
            report.result = 'skipped'
            return
        listed = mine[0].get('name') if isinstance(mine[0].get('name'), str) else mine[0].get('model')
        report.stage = 'POST /api/generate'
        async with self.ollama_http.post(self.ollama + '/api/generate', json={'model': listed, 'keep_alive': 0}) as answer:
            if answer.status != 200:
                raise OllamaError(f'POST /api/generate answered {answer.status}')
            await answer.read()
        report.stage = f'waiting until /api/ps no longer lists {self.model}'
        while True:
            await asyncio.sleep(self.poll_seconds)
            if not any(self.is_chat_model(m) for m in await self.loaded_models()):
                report.result = 'unloaded'
                return

    # Return the model entries GET <ollama>/api/ps lists; raise OllamaError for another status or a
    # body without a models list.
    async def loaded_models(self):
        async with self.ollama_http.get(self.ollama + '/api/ps') as answer:
            if answer.status != 200:
                raise OllamaError(f'GET /api/ps answered {answer.status}')
            data = await answer.json(content_type=None)
        if not isinstance(data, dict) or 'models' not in data:
            raise OllamaError('GET /api/ps answered without a models list')
        models = data['models'] if data['models'] is not None else []
        if not isinstance(models, list):
            raise OllamaError('GET /api/ps answered without a models list')
        return [m for m in models if isinstance(m, dict)]

    # Return True when the /api/ps $entry is the chat model, by name or model, with or without ':latest'.
    def is_chat_model(self, entry):
        return any(isinstance(entry.get(key), str) and full_model_name(entry[key]) == self.wanted for key in ('name', 'model'))

    # Log the one line for a queued prompt: what the unload step did and how long it took, the other
    # loaded models, then $outcome. A failed unload makes it a WARNING line.
    def log_prompt(self, report, path, outcome):
        if report.problem:
            text = (f'WARNING prompt {path}: {self.model} was not unloaded ({report.problem}) after {report.elapsed_ms} ms; '
                    'forwarded anyway, so ComfyUI shares the GPU with it')
        elif report.result == 'unloaded':
            text = f'prompt {path}: unloaded {self.model} in {report.elapsed_ms} ms'
        elif report.result == 'skipped':
            text = f'prompt {path}: {self.model} was not unloaded, as the client had closed the connection ({report.elapsed_ms} ms)'
        else:
            text = f'prompt {path}: {self.model} was not loaded (checked in {report.elapsed_ms} ms)'
        if report.others:
            text += '; left loaded: ' + ', '.join(f'{name} (size_vram {size})' for name, size in report.others)
        self.log(f'{text}; {outcome}')


# Parse the command line, route aiohttp's and asyncio's log records to the gate's one-line log, serve
# the gate on 127.0.0.1 until the process is stopped and return the exit code: 1 when the port
# cannot be bound, as when another program holds it.
def main(argv=None):
    options = parse_arguments(argv)
    gate = Gate(options.port, options.upstream, options.ollama, options.model, options.unload_timeout)
    # Without a handler of their own, aiohttp's and asyncio's errors reach stderr as tracebacks with raw request bytes.
    handler = OneLineLogHandler(gate)
    for name in ('aiohttp', 'asyncio'):
        logger = logging.getLogger(name)
        logger.handlers[:] = [handler]
        logger.propagate = False
        logger.setLevel(logging.WARNING)
    gate.log(f'image gate {VERSION} on 127.0.0.1:{options.port} in front of {gate.upstream}; unloads {options.model} '
             f'from {gate.ollama} before each prompt, waiting up to {options.unload_timeout:g} s')
    try:
        web.run_app(gate.make_app(), host='127.0.0.1', port=options.port, access_log=None, print=None)
    except OSError as error:
        gate.log(f'cannot listen on 127.0.0.1:{options.port}: {error.strerror or error}')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
