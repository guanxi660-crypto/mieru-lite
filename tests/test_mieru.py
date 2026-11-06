"""契约测试：E1 首位用户 ip_ver 落盘、E2 端口段中间占用、E3 单用户凭据隔离。

运行：WSL bash -c "cd tests && python3 -m unittest test_mieru -v"
"""
import json
import socket
import unittest
from shell_harness import run_shell


class MieruContracts(unittest.TestCase):
    def test_first_user_keeps_selected_ipv6(self):
        # _modify_ports_from_add 真实执行（落盘点在此）；stdin 两个 Enter 走默认
        out = run_shell('''
_init_metadata() { :; }
_probe_ports() { :; }
_ask_ip_ver() { IP_VER=v6; }
_pick_port() { echo 32123; }
_check_spec_free() { return 0; }
_user_create() { :; }
_add_user >/dev/null
cat "$METADATA_FILE"
''', {"ip_ver": "v4", "ports": [], "users": []}, stdin="\n\n")
        self.assertEqual(json.loads(out)["ip_ver"], "v6")

    def test_occupied_middle_port_rejects_range(self):
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            sock.listen()
            port = sock.getsockname()[1]
            out = run_shell(f'''
if _check_spec_free "{port - 1}-{port + 1}"; then echo ACCEPT; else echo REJECT; fi
''', {"ports": [], "users": []})
        self.assertEqual(out.strip(), "REJECT")

    def test_single_user_export_does_not_include_other_passwords(self):
        metadata = {"ip_ver": "v4", "mtu": 1400, "multiplexing": "MULTIPLEXING_LOW",
                    "ports": [{"port": 32123, "protocol": "TCP"}], "users": [
                        {"name": "alice", "password": "alice-audit-only"},
                        {"name": "bob", "password": "bob-private-audit-only"}]}
        out = run_shell('''
_resolve_node_ip() { echo 192.0.2.1; }
_geo_name() { echo TW; }
_show_user_link alice
''', metadata)
        self.assertIn("alice-audit-only", out)
        self.assertNotIn("bob-private-audit-only", out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
