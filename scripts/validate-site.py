#!/usr/bin/env python3

from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / "docs"
INDEX = SITE / "index.html"


class SiteParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.ids: list[str] = []
        self.references: list[tuple[str, str]] = []
        self.images_without_alt: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = dict(attrs)
        element_id = values.get("id")
        if element_id:
            self.ids.append(element_id)

        for attribute in ("href", "src"):
            value = values.get(attribute)
            if value:
                self.references.append((attribute, value))

        if tag == "img" and "alt" not in values:
            self.images_without_alt.append(values.get("src", "<unknown>"))


def fail(message: str) -> None:
    raise SystemExit(f"site validation failed: {message}")


def main() -> None:
    if not INDEX.is_file():
        fail("docs/index.html is missing")

    if (SITE / "CNAME").read_text().strip() != "bobbin.combinatrix.ai":
        fail("docs/CNAME must contain bobbin.combinatrix.ai")

    parser = SiteParser()
    parser.feed(INDEX.read_text())
    parser.close()

    duplicate_ids = sorted({value for value in parser.ids if parser.ids.count(value) > 1})
    if duplicate_ids:
        fail(f"duplicate ids: {', '.join(duplicate_ids)}")

    if parser.images_without_alt:
        fail(f"images without alt attributes: {', '.join(parser.images_without_alt)}")

    known_ids = set(parser.ids)
    for attribute, reference in parser.references:
        if reference.startswith("#"):
            if reference[1:] not in known_ids:
                fail(f"missing fragment target: {reference}")
            continue

        parsed = urlsplit(reference)
        if parsed.scheme or reference.startswith("//") or reference.startswith("mailto:"):
            continue

        asset = SITE / parsed.path
        if not asset.is_file():
            fail(f"missing local asset referenced by {attribute}: {reference}")

    print(f"validated {INDEX.relative_to(ROOT)} and {len(parser.references)} references")


if __name__ == "__main__":
    main()
