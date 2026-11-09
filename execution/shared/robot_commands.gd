extends RefCounted

# Add all new commands here — both C++ and Python update automatically

# Command functions, alters player state
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

## Socket bootstrap + a synthesized 'robot' module containing all commands and sensors.
func get_python_bootstrap(port: int, token: String) -> String:
	var lines := [
		"import socket as _socket, sys, traceback, types",
		"",
		"_sock = _socket.create_connection(('127.0.0.1', %d))" % port,
		"_sock_file = _sock.makefile('rwb', buffering=1)",
		"",
		"def _robot_send(msg):",
		"    # Cap wire size: the worker's pipe read and the IPC line limit are 8192.",
		"    # Only free-text tails ([PRINT]/[ERROR]) can exceed this; protocol",
		"    # fields like [CMD]/[QUERY]/[LINE] are always small and at the front.",
		"    if len(msg) > 8000:",
		"        msg = msg[:7997] + '...'",
		"    _sock_file.write((msg + '\\n').encode())",
		"    _sock_file.flush()",
		"",
		"def _robot_recv():",
		"    return _sock_file.readline().decode().strip()",
		"",
		"_robot_send('[AUTH] %s')" % token,
		"",
		"# Route student print() through the socket to the output panel",
		"# print() calls write() once per argument, so buffer until newline.",
		"def _robot_print(text):",
		"    # Truncate so '[PRINT] ' + text stays under the 8000-char send cap;",
		"    # an oversized message would kill the worker's 8KB pipe read.",
		"    if len(text) > 7989:",
		"        text = text[:7989] + '...'",
		"    _robot_send('[PRINT] ' + text)",
		"class _SockStdout:",
		"    def __init__(self):",
		"        self._pending = ''",
		"    def write(self, s):",
		"        self._pending += s",
		"        while '\\n' in self._pending:",
		"            _line, self._pending = self._pending.split('\\n', 1)",
		"            if _line:",
		"                _robot_print(_line.rstrip('\\r'))",
		"    def flush(self):",
		"        if self._pending:",
		"            _robot_print(self._pending)",
		"            self._pending = ''",
		"sys.stdout = _SockStdout()",
		"",
		"# Build the 'robot' module dynamically and register it so student code",
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
	# Commands: send [CMD], wait for Godot's OK before continuing
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
		"    # Cap wire size: the worker's pipe read and the IPC line limit are 8192.",
		"    # Only free-text tails ([PRINT]/[ERROR]) can exceed this; protocol",
		"    # fields like [CMD]/[QUERY]/[LINE] are always small and at the front.",
		"    if len(msg) > 8000:",
		"        msg = msg[:7997] + '...'",
		"    _pipe.write((msg + '\\n').encode())",
		"    _pipe.flush()",
		"",
		"def _robot_recv():",
		"    _reply = _pipe.readline()",
		"    if not _reply:",
		"        return ''",
		"    return _reply.decode().rstrip('\\r\\n')",
		"",
		"# print() calls write() once per argument, so buffer until newline.",
		"def _robot_print(text):",
		"    # Truncate so '[PRINT] ' + text stays under the 8000-char send cap;",
		"    # an oversized message would kill the worker's 8KB pipe read.",
		"    if len(text) > 7989:",
		"        text = text[:7989] + '...'",
		"    _robot_send('[PRINT] ' + text)",
		"class _PipeStdout:",
		"    def __init__(self):",
		"        self._pending = ''",
		"    def write(self, text):",
		"        self._pending += text",
		"        while '\\n' in self._pending:",
		"            _line, self._pending = self._pending.split('\\n', 1)",
		"            if _line:",
		"                _robot_print(_line.rstrip('\\r'))",
		"    def flush(self):",
		"        if self._pending:",
		"            _robot_print(self._pending)",
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


## Error-catching wrapper around the student's code. Always sends [DONE].
func get_python_runner(student_code: String) -> String:
	var escaped := student_code.replace("\\", "\\\\").replace('"""', '\\"\\"\\"')
	return "\n".join([
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


## robot_runtime.cpp — cross-platform socket bootstrap + all implementations.
## Port is baked in at generation time so no runtime argument is needed.
func get_cpp_source(port: int, token: String) -> String:
	var lines := [
		"#include \"robot.hpp\"",
		"#include <string>",
		"#include <cstdint>",
		"",
		"#ifdef _WIN32",
		"#  ifndef _WIN32_WINNT",
		"#    define _WIN32_WINNT 0x0601",
		"#  endif",
		"#  define WIN32_LEAN_AND_MEAN",
		"#  include <winsock2.h>",
		"#  include <ws2tcpip.h>",
		"   typedef SOCKET __sock_t;",
		"#  define __sock_close(s) closesocket(s)",
		"#else",
		"#  include <sys/socket.h>",
		"#  include <arpa/inet.h>",
		"#  include <unistd.h>",
		"   typedef int __sock_t;",
		"#  define __sock_close(s) close(s)",
		"#endif",
		"",
		"static __sock_t __robot_sock;",
		"static std::string __robot_buf;",
		"",
		"static void __robot_connect() {",
		"#ifdef _WIN32",
		"    WSADATA wsa; WSAStartup(MAKEWORD(2,2), &wsa);",
		"#endif",
		"    __robot_sock = socket(AF_INET, SOCK_STREAM, 0);",
		"    struct sockaddr_in addr{};",
		"    addr.sin_family      = AF_INET;",
		"    addr.sin_port        = htons(%d);" % port,
		"    addr.sin_addr.s_addr = inet_addr(\"127.0.0.1\");",
		"    connect(__robot_sock, (struct sockaddr*)&addr, sizeof(addr));",
		"}",
		"",
		"static void __robot_send(const std::string& msg) {",
		"    std::string line = msg + \"\\n\";",
		"    send(__robot_sock, line.c_str(), (int)line.size(), 0);",
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
		"        int n = recv(__robot_sock, tmp, sizeof(tmp), 0);",
		"        if (n <= 0) return \"\";",
		"        __robot_buf.append(tmp, n);",
		"    }",
		"}",
		"",
		"struct __RobotLifetime {",
		"    __RobotLifetime()  { __robot_connect(); __robot_send(\"[AUTH] %s\"); }" % token,
		"    ~__RobotLifetime() { __robot_send(\"[DONE]\"); __sock_close(__robot_sock); }",
		"} __robot_lifetime;",
		"",
	]
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
	return "\n".join(lines)


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

	return "\n".join(lines)


## Preprocessor macros so the student writes move() and __LINE__ is injected automatically
func get_cpp_macros() -> String:
	var lines := []
	for cmd in COMMANDS:
		lines.append("#define %s() %s(__LINE__)" % [cmd.name, cmd.name])
	for sensor in SENSORS:
		lines.append("#define %s() %s(__LINE__)" % [sensor.name, sensor.name])
	return "\n".join(lines)
