"""Offline checks for website assets and shared launch copy."""
from html import unescape
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit
import re
import unittest

ROOT = Path(__file__).resolve().parents[1] / 'site'

def plain_text(markup):
    return ' '.join(unescape(re.sub(r'<[^>]+>|\*\*|`', '', markup)).split())

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
        self.assertNotIn('nightr setup', html)
        self.assertIn('nightr config', html)
        self.assertNotIn('/releases/download/', html)
        self.assertNotIn('drag Nightr', html)
        self.assertEqual((ROOT / 'CNAME').read_text().strip(), 'nightr.ai')
        self.assertTrue((ROOT / '.nojekyll').exists())

    def test_readme_and_website_feature_copy(self):
        html = (ROOT / 'index.html').read_text()
        readme = (ROOT.parent / 'README.md').read_text()
        features = html.partition('id="features"')[2].partition('</section>')[0]
        cards = re.findall(r'<h2>(.*?)</h2>\s*<p>(.*?)</p>', features, re.DOTALL)
        self.assertTrue(cards)

        readme_features = readme.partition('## What it does\n')[2].partition('\n## ')[0]
        lid_copy, *feature_items = readme_features.split('\n- ')
        site_lid_copy = html.partition('<p class="lede">')[2].partition('. ')[0]
        self.assertEqual(plain_text(lid_copy), site_lid_copy + '.')
        self.assertEqual(
            [plain_text(item) for item in feature_items],
            [plain_text(f'{title}. {description}') for title, description in cards],
        )

    def test_readme_and_website_cli_copy(self):
        html = (ROOT / 'index.html').read_text()
        readme = (ROOT.parent / 'README.md').read_text()
        cli = html.partition('id="cli"')[2].partition('</section>')[0]
        heading = cli.partition('<h2>')[2].partition('</h2>')[0]
        description, compatibility = re.findall(r'<p(?: class="meta")?>(.*?)</p>', cli)
        commands = re.findall(r'<span>\$ (.*?)</span>', cli)
        readme_cli = readme.partition(f'## {heading}\n')[2].partition('\n## ')[0]
        intro, _, example = readme_cli.partition('\n```sh\n')
        readme_commands, _, notes = example.partition('\n```')
        self.assertEqual(plain_text(intro), plain_text(description))
        self.assertEqual(readme_commands.splitlines(), commands)
        self.assertEqual(plain_text(notes.strip().splitlines()[0]), plain_text(compatibility))
        self.assertNotIn('nightr setup', readme)

if __name__ == '__main__':
    unittest.main()
