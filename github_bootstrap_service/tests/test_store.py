import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from bootstrap_service.store import BootstrapSessionStore


class BootstrapSessionStoreTests(unittest.TestCase):
    def test_create_and_update_session(self) -> None:
        store = BootstrapSessionStore(ttl_seconds=300)
        session = store.create_session(chatgpt_email="user@example.com")
        self.assertEqual(session.chatgpt_email, "user@example.com")

        updated = store.update_status(session.session_id, status="redirected_to_github")
        self.assertIsNotNone(updated)
        self.assertEqual(updated.status, "redirected_to_github")

        fetched = store.get_session(session.session_id)
        self.assertIsNotNone(fetched)
        self.assertEqual(fetched.status, "redirected_to_github")
        self.assertIsNotNone(store.get_session_for_state(session.state))


if __name__ == "__main__":
    unittest.main()
