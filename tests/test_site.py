"""Offline checks for the published site's assets and installation paths."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit
import unittest

ROOT = Path(__file__).resolve().parents[1] / 'site'

class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = []
        self.urls = []
        self.images = []
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if 'id' in attrs:
            self.ids.append(attrs['id'])
        for key in ('href', 'src'):
            if attrs.get(key):
                self.urls.append(attrs[key])
        if tag == 'img':
            self.images.append(attrs)

class SiteTests(unittest.TestCase):
    def test_local_assets_and_navigation(self):
        page = Page()
        page.feed((ROOT / 'index.html').read_text())
        self.assertEqual(len(page.ids), len(set(page.ids)))
        for url in page.urls:
            parsed = urlsplit(url)
            if parsed.scheme or parsed.netloc:
                continue
            if parsed.fragment:
                self.assertIn(parsed.fragment, page.ids)
            if parsed.path:
                self.assertTrue((ROOT / parsed.path).exists(), url)
        self.assertTrue(page.images)
        self.assertTrue(all('alt' in image for image in page.images))
        self.assertIn('main', page.ids)
    def test_install_links_and_commands(self):
        html = (ROOT / 'index.html').read_text()
        self.assertIn('href="https://github.com/agenthangar/nightr/releases"', html)
        self.assertIn('Open the signed DMG and run the included installer.', html)
        self.assertIn('brew install --cask agenthangar/tap/nightr', html)
        self.assertNotRegex(html, r'(?i)\bpre-release\b|\bt install\b')
        self.assertIn('nightr setup', html)
        self.assertIn('nightr config', html)
        self.assertNotIn('/releases/download/', html)
        self.assertNotIn('drag Nightr', html)
        self.assertEqual((ROOT / 'CNAME').read_text().strip(), 'nightr.ai')
        self.assertTrue((ROOT / '.nojekyll').exists())

if __name__ == '__main__':
    unittest.main()
