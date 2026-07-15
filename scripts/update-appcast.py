#!/usr/bin/env python3
"""Prepend a release item to appcast.xml (Sparkle auto-update feed).

Usage: update-appcast.py <appcast.xml> <version> <pkg-url> <sig-attrs>
  sig-attrs is sign_update's output: sparkle:edSignature="..." length="..."
"""
import sys
from email.utils import formatdate

path, version, url, sig_attrs = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

item = f"""    <item>
      <title>v{version}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{version}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <link>https://github.com/jcanizalez/ode/releases/tag/v{version}</link>
      <enclosure url="{url}" {sig_attrs.strip()} type="application/octet-stream"/>
    </item>
"""

content = open(path).read()
if f"<sparkle:version>{version}</sparkle:version>" in content:
    print(f"appcast already has v{version}, skipping")
    sys.exit(0)
marker = "<language>en</language>\n"
content = content.replace(marker, marker + item, 1)
open(path, "w").write(content)
print(f"appcast: added v{version}")
