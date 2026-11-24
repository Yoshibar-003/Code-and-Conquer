extends RefCounted

# IPC protocol between the student program and Godot (relayed by the sandbox
# worker; see execution/shared/ipc_server.gd for the worker-facing side).
# Student -> Godot, one tag per line:
#   [AUTH] <token>            one-time handshake token
#   [CMD] <NAME> [LINE] <n>   robot command; <n> is the student's 1-indexed
#                             source line, used for highlighting/step-back
#   [QUERY] <NAME> [LINE] <n> sensor query
#   [PRINT] <text>            student print() output
#   [ERROR] <text>            unhandled student exception
#   [DONE]                    student program finished
# Godot -> student replies: "OK" acknowledges a [CMD]; "true"/"false" answers
# a [QUERY]. ipc_server.gd also surfaces control lines ([CANCELLED],
# [DISCONNECT], [AUTH_FAILED], [PROTOCOL_ERROR]) that never reach this parser.
# COMMANDS and SENSORS below are the single source of truth for the robot API;
# add new student-facing functions there only.

# Add all new commands here — both C++ and Python update automatically

# Command functions, alters player state
# To whom it concerns: no turn_right command is intentional (there's no
# turn_right command in Reeborg's World), only turn_left.
const COMMANDS := [
	{ "name": "move",        "cmd": "MOVE"        },
	{ "name": "turn_left",   "cmd": "TURN_LEFT"   },
	{ "name": "pick_object", "cmd": "PICK_OBJECT" },
	{ "name": "put_object",  "cmd": "PUT_OBJECT"  },
]

# Sensor functions, returns bool
const SENSORS := [
	{ "name": "front_is_clear",  "query": "FRONT_IS_CLEAR"  },
	{ "name": "right_is_clear",  "query": "RIGHT_IS_CLEAR"  },
	{ "name": "left_is_clear",   "query": "LEFT_IS_CLEAR"   },
	{ "name": "wall_in_front",   "query": "WALL_IN_FRONT"   },
	{ "name": "wall_on_right",   "query": "WALL_ON_RIGHT"   },
	{ "name": "wall_on_left",    "query": "WALL_ON_LEFT"    },
	{ "name": "at_goal",         "query": "AT_GOAL"         },
	{ "name": "object_here",     "query": "OBJECT_HERE"     },
	{ "name": "carries_object",  "query": "CARRIES_OBJECT"  },
	{ "name": "is_facing_north", "query": "IS_FACING_NORTH" },
	{ "name": "is_facing_east", "query": "IS_FACING_EAST" },
	{ "name": "is_facing_south", "query": "IS_FACING_SOUTH" },
	{ "name": "is_facing_west", "query": "IS_FACING_WEST" },
]

## Named-pipe bootstrap for the AppContainer sandbox. The worker creates the pipe
## as PIPE_TYPE_MESSAGE but the Python client never sets PIPE_READMODE_MESSAGE, so
## it reads in byte mode; newline-delimited replies make buffered readline() safe.
func get_python_pipe_bootstrap(pipe_name: String) -> String:
	var escaped_pipe_name := pipe_name.replace("\\", "\\\\").replace("'", "\\'")

	var lines := [
		"import sys, traceback, types",
		"",
		"_pipe = open('%s', 'r+b')" % escaped_pipe_name,
		"_sock = _pipe",
		"",
		"def _robot_send(msg):",
		"    # Cap wire size in BYTES, not characters: UTF-8 uses up to 4 bytes",
		"    # per character and the worker's pipe read / IPC line limit are ~8KB.",
		"    # Only free-text tails ([PRINT]/[ERROR]) can exceed this; protocol",
		"    # fields like [CMD]/[QUERY]/[LINE] are always small and at the front.",
		"    _data = (msg + '\\n').encode()",
		"    if len(_data) > 8000:",
		"        # decode('ignore') drops a partial UTF-8 sequence at the cut.",
		"        msg = _data[:7997].decode('utf-8', 'ignore') + '...'",
		"        _data = (msg + '\\n').encode()",
		"    _pipe.write(_data)",
		"    _pipe.flush()",
		"",
		"def _robot_recv():",
		"    _reply = _pipe.readline()",
		"    if not _reply:",
		"        return ''",
		"    return _reply.decode().rstrip('\\r\\n')",
		"",
		"# print() calls write() once per argument, so buffer until newline.",
		"class _PipeStdout:",
		"    def __init__(self):",
		"        self._pending = ''",
		"    def write(self, text):",
		"        self._pending += text",
		"        while '\\n' in self._pending:",
		"            _line, self._pending = self._pending.split('\\n', 1)",
		"            if _line:",
		"                _robot_send('[PRINT] ' + _line.rstrip('\\r'))",
		"    def flush(self):",
		"        if self._pending:",
		"            _robot_send('[PRINT] ' + self._pending)",
		"            self._pending = ''",
		"",
		"sys.stdout = _PipeStdout()",
		"",
		"_robot_mod = types.ModuleType('robot')",
		"_robot_exports = []",
		"",
		"def _mk_cmd(_cmd):",
		"    def _fn():",
		"        # sys._getframe(1) is the caller's frame; f_lineno is the student's call site.",
		"        _robot_send('[CMD] ' + _cmd + ' [LINE] ' + str(sys._getframe(1).f_lineno))",
		"        _robot_recv()",
		"    return _fn",
		"",
		"def _mk_sensor(_query):",
		"    def _fn():",
		"        _robot_send('[QUERY] ' + _query + ' [LINE] ' + str(sys._getframe(1).f_lineno))",
		"        return _robot_recv() == 'true'",
		"    return _fn",
		"",
	]

	for cmd in COMMANDS:
		lines.append("setattr(_robot_mod, '%s', _mk_cmd('%s'))" % [cmd.name, cmd.cmd])
		lines.append("_robot_exports.append('%s')" % cmd.name)

	for sensor in SENSORS:
		lines.append("setattr(_robot_mod, '%s', _mk_sensor('%s'))" % [sensor.name, sensor.query])
		lines.append("_robot_exports.append('%s')" % sensor.name)

	lines.append("_robot_mod.__all__ = _robot_exports")
	lines.append("sys.modules['robot'] = _robot_mod")
	lines.append("")

	return "\n".join(lines)


func get_python_unix_bootstrap(socket_path: String) -> String:
	var escaped_socket_path := socket_path.replace("\\", "\\\\").replace("'", "\\'")

	var lines := [
		"import socket as _socket, sys, traceback, types, time",
		"",
		"_sock = _socket.socket(_socket.AF_UNIX, _socket.SOCK_STREAM)",
		"for _attempt in range(100):",
		"	try:",
		"		_sock.connect('%s')" % escaped_socket_path,
		"		break",
		"	except OSError:",
		"		if _attempt == 99:",
		"			raise",
		"		time.sleep(0.1)",
		"_pipe = _sock.makefile('rwb', buffering=1)",
		"",
		"def _robot_send(msg):",
		"	# Cap wire size in BYTES, not characters: UTF-8 uses up to 4 bytes",
		"	# per character and the worker's pipe read / IPC line limit are ~8KB.",
		"	# Only free-text tails ([PRINT]/[ERROR]) can exceed this; protocol",
		"	# fields like [CMD]/[QUERY]/[LINE] are always small and at the front.",
		"	_data = (msg + '\\n').encode()",
		"	if len(_data) > 8000:",
		"		# decode('ignore') drops a partial UTF-8 sequence at the cut.",
		"		msg = _data[:7997].decode('utf-8', 'ignore') + '...'",
		"		_data = (msg + '\\n').encode()",
		"	_pipe.write(_data)",
		"	_pipe.flush()",
		"",
		"def _robot_recv():",
		"	_reply = _pipe.readline()",
		"	if not _reply:",
		"		return ''",
		"	return _reply.decode().rstrip('\\r\\n')",
		"",
		"# print() calls write() once per argument, so buffer until newline.",
		"class _UnixStdout:",
		"	def __init__(self):",
		"		self._pending = ''",
		"	def write(self, text):",
		"		self._pending += text",
		"		while '\\n' in self._pending:",
		"			_line, self._pending = self._pending.split('\\n', 1)",
		"			if _line:",
		"				_robot_send('[PRINT] ' + _line.rstrip('\\r'))",
		"	def flush(self):",
		"		if self._pending:",
		"			_robot_send('[PRINT] ' + self._pending)",
		"			self._pending = ''",
		"",
		"sys.stdout = _UnixStdout()",
		"",
		"_robot_mod = types.ModuleType('robot')",
		"_robot_exports = []",
		"",
		"def _mk_cmd(_cmd):",
		"	def _fn():",
		"		# sys._getframe(1) is the caller's frame; f_lineno is the student's call site.",
		"		_robot_send('[CMD] ' + _cmd + ' [LINE] ' + str(sys._getframe(1).f_lineno))",
		"		_robot_recv()",
		"	return _fn",
		"",
		"def _mk_sensor(_query):",
		"	def _fn():",
		"		_robot_send('[QUERY] ' + _query + ' [LINE] ' + str(sys._getframe(1).f_lineno))",
		"		return _robot_recv() == 'true'",
		"	return _fn",
		"",
	]

	for cmd in COMMANDS:
		lines.append("setattr(_robot_mod, '%s', _mk_cmd('%s'))" % [cmd.name, cmd.cmd])
		lines.append("_robot_exports.append('%s')" % cmd.name)

	for sensor in SENSORS:
		lines.append("setattr(_robot_mod, '%s', _mk_sensor('%s'))" % [sensor.name, sensor.query])
		lines.append("_robot_exports.append('%s')" % sensor.name)

	lines.append("_robot_mod.__all__ = _robot_exports")
	lines.append("sys.modules['robot'] = _robot_mod")
	lines.append("")

	return "\n".join(lines)


## Error-catching wrapper around the student's code. Always sends [DONE].
func get_python_runner(student_code: String) -> String:
	var escaped := student_code.replace("\\", "\\\\").replace('"""', '\\"\\"\\"')
	return "\n".join([
		"_robot_stdout = sys.stdout",
		"_player_src = \"\"\"" + escaped + "\"\"\"",
		"try:",
		"    exec(compile(_player_src, '<player_code>', 'exec'))",
		"except SyntaxError as _e:",
		"    _robot_send('[ERROR] SyntaxError: ' + str(_e.msg) + ' (line ' + str(_e.lineno) + ')')",
		"except Exception as _e:",
		"    _tb = traceback.extract_tb(sys.exc_info()[2])",
		"    _pf = [f for f in _tb if f.filename == '<player_code>']",
		"    if _pf:",
		"        _robot_send('[ERROR] ' + type(_e).__name__ + ': ' + str(_e) + ' (line ' + str(_pf[-1].lineno) + ')')",
		"    else:",
		"        _robot_send('[ERROR] ' + type(_e).__name__ + ': ' + str(_e))",
		"finally:",
		"    try:",
		"        _robot_stdout.flush()",
		"    except Exception:",
		"        pass",
		"    _robot_send('[DONE]')",
		"    _sock.close()",
	])


## robot.hpp — forward declarations for all commands and sensors
func get_cpp_header() -> String:
	var lines := ["#pragma once", "#include <string>", ""]
	for cmd in COMMANDS:
		lines.append("void %s(int __src_line = 0);" % cmd.name)
	lines.append("")
	for sensor in SENSORS:
		lines.append("bool %s(int __src_line = 0);" % sensor.name)
	return "\n".join(lines)


func _cpp_command_implementation_lines() -> Array:
	var lines := []
	for cmd in COMMANDS:
		lines.append("void %s(int __src_line) {" % cmd.name)
		lines.append("    __robot_send(\"[CMD] %s [LINE] \" + std::to_string(__src_line));" % cmd.cmd)
		lines.append("    __robot_recv();")
		lines.append("}")
		lines.append("")
	for sensor in SENSORS:
		lines.append("bool %s(int __src_line) {" % sensor.name)
		lines.append("    __robot_send(\"[QUERY] %s [LINE] \" + std::to_string(__src_line));" % sensor.query)
		lines.append("    return __robot_recv() == \"true\";")
		lines.append("}")
		lines.append("")
	return lines


func get_cpp_pipe_source() -> String:
	var lines := [
		"#include <fstream>",
		"#include \"robot.hpp\"",
		"#include <windows.h>",
		"#include <string>",
		"#include <cstdint>",
		"",
		"static HANDLE __robot_pipe = INVALID_HANDLE_VALUE;",
		"",
		"static void __robot_connect() {",
		"    std::wifstream pipe_file(L\"connection.txt\");",
		"    std::wstring pipe_name;",
		"    std::getline(pipe_file, pipe_name);",
		"    if (pipe_name.empty()) return;",
		"    WaitNamedPipeW(pipe_name.c_str(), 5000);",
		"    __robot_pipe = CreateFileW(",
		"        pipe_name.c_str(),",
		"        GENERIC_READ | GENERIC_WRITE,",
		"        0,",
		"        nullptr,",
		"        OPEN_EXISTING,",
		"        0,",
		"        nullptr",
		"    );",
		"    if (__robot_pipe != INVALID_HANDLE_VALUE) {",
		"        DWORD mode = PIPE_READMODE_MESSAGE;",
		"        SetNamedPipeHandleState(__robot_pipe, &mode, nullptr, nullptr);",
		"    }",
		"}",
		"",
		"static void __robot_send(const std::string& message) {",
		"    if (__robot_pipe == INVALID_HANDLE_VALUE) return;",
		"    std::string line = message + \"\\n\";",
		"    DWORD written = 0;",
		"    WriteFile(__robot_pipe, line.data(), static_cast<DWORD>(line.size()), &written, nullptr);",
		"}",
		"",
		"static std::string __robot_recv() {",
		"    if (__robot_pipe == INVALID_HANDLE_VALUE) return \"\";",
		"    char buffer[8192]{};",
		"    DWORD read = 0;",
		"    if (!ReadFile(__robot_pipe, buffer, sizeof(buffer), &read, nullptr)) return \"\";",
		"    std::string reply(buffer, read);",
		"    while (!reply.empty() && (reply.back() == '\\n' || reply.back() == '\\r')) reply.pop_back();",
		"    return reply;",
		"}",
		"",
		"struct __RobotLifetime {",
		"    __RobotLifetime() { __robot_connect(); }",
		"    ~__RobotLifetime() {",
		"        __robot_send(\"[DONE]\");",
		"        if (__robot_pipe != INVALID_HANDLE_VALUE) CloseHandle(__robot_pipe);",
		"    }",
		"} __robot_lifetime;",
		"",
	]
	lines.append_array(_cpp_command_implementation_lines())
	return "\n".join(lines)


func get_cpp_unix_source() -> String:
	var lines := [
		"#include <fstream>",
		"#include \"robot.hpp\"",
		"#include <string>",
		"#include <cstdint>",
		"#include <cstring>",
		"#include <cerrno>",
		"#include <sys/socket.h>",
		"#include <sys/un.h>",
		"#include <unistd.h>",
		"",
		"static int __robot_sock = -1;",
		"static std::string __robot_buf;",
		"",
		"static void __robot_connect() {",
		"    std::ifstream endpoint_file(\"connection.txt\");",
		"    std::string endpoint;",
		"    std::getline(endpoint_file, endpoint);",
		"    while (!endpoint.empty() && (endpoint.back() == '\\n' || endpoint.back() == '\\r')) endpoint.pop_back();",
		"    if (endpoint.empty() || endpoint.size() >= sizeof(((sockaddr_un*)nullptr)->sun_path)) return;",
		"    for (int attempt = 0; attempt < 100; ++attempt) {",
		"        int sock = socket(AF_UNIX, SOCK_STREAM, 0);",
		"        if (sock < 0) return;",
		"        sockaddr_un addr{};",
		"        addr.sun_family = AF_UNIX;",
		"        std::strncpy(addr.sun_path, endpoint.c_str(), sizeof(addr.sun_path) - 1);",
		"        if (connect(sock, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0) {",
		"            __robot_sock = sock;",
		"            return;",
		"        }",
		"        close(sock);",
		"        usleep(100000);",
		"    }",
		"}",
		"",
		"static void __robot_send(const std::string& message) {",
		"    if (__robot_sock < 0) return;",
		"    std::string line = message + \"\\n\";",
		"    size_t sent = 0;",
		"    while (sent < line.size()) {",
		"        ssize_t n = send(__robot_sock, line.data() + sent, line.size() - sent, 0);",
		"        if (n <= 0) return;",
		"        sent += static_cast<size_t>(n);",
		"    }",
		"}",
		"",
		"static std::string __robot_recv() {",
		"    while (true) {",
		"        auto pos = __robot_buf.find('\\n');",
		"        if (pos != std::string::npos) {",
		"            std::string line = __robot_buf.substr(0, pos);",
		"            __robot_buf = __robot_buf.substr(pos + 1);",
		"            if (!line.empty() && line.back() == '\\r') line.pop_back();",
		"            return line;",
		"        }",
		"        char tmp[256];",
		"        ssize_t n = recv(__robot_sock, tmp, sizeof(tmp), 0);",
		"        if (n <= 0) return \"\";",
		"        __robot_buf.append(tmp, static_cast<size_t>(n));",
		"    }",
		"}",
		"",
		"struct __RobotLifetime {",
		"    __RobotLifetime() { __robot_connect(); }",
		"    ~__RobotLifetime() {",
		"        __robot_send(\"[DONE]\");",
		"        if (__robot_sock >= 0) close(__robot_sock);",
		"    }",
		"} __robot_lifetime;",
		"",
	]
	lines.append_array(_cpp_command_implementation_lines())
	return "\n".join(lines)


## Preprocessor macros so the student writes move() and __LINE__ is injected automatically
func get_cpp_macros() -> String:
	var lines := []
	for cmd in COMMANDS:
		lines.append("#define %s() %s(__LINE__)" % [cmd.name, cmd.name])
	for sensor in SENSORS:
		lines.append("#define %s() %s(__LINE__)" % [sensor.name, sensor.name])
	return "\n".join(lines)
