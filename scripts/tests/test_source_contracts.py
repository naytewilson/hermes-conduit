"""Checkout-local source contracts that must not depend on compiled #filePath values."""

from pathlib import Path
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
ROOT_VIEW = REPO_ROOT / "Conduit" / "Views" / "RootView.swift"


class RootViewSourceContractTests(unittest.TestCase):
    def test_duplicate_window_uses_environment_scoped_dismissal(self):
        source = ROOT_VIEW.read_text(encoding="utf-8")
        self.assertIn(
            "@Environment(\\.dismissWindow)",
            source,
            "RootView must source dismissal from SwiftUI's environment action",
        )
        self.assertIn(
            "dismissWindow()",
            source,
            "the duplicate foreground window must dismiss only its current instance",
        )
        self.assertNotIn(
            "dismissWindow(id:",
            source,
            "ID-scoped dismissal would target the WindowGroup, including the primary window",
        )


if __name__ == "__main__":
    unittest.main()
