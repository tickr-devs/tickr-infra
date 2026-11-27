"""Fails when a stack's rendered first-boot script is over EC2's user-data limit.

EC2 refuses user data over 16,384 bytes (the decoded bytes: plain text, or the gzip stream when
the stack passes base64gzip(...)). `terraform validate` never renders templatefile(), so only a
plan found the overflow of tickr-infra #5; this check renders the script the way main.tf does and
measures it in CI.

    python3 ops/aws/checks/user_data_size.py ops/aws/bot ops/aws/web

Rendering: ${files["NAME"]} becomes the base64 of files/NAME (as filebase64() in main.tf), every
other ${name} a 64-character stand-in (longer than any real value: ids, versions, domains,
sha256), and $${ the literal ${. The script refuses a template directive (%{), which it does not
render."""

import base64
import gzip
import re
import sys
from pathlib import Path

LIMIT_BYTES = 16384  # EC2 user-data limit (AWS protocol constant).
STAND_IN = "x" * 64  # Upper bound for one interpolated value; a sha256 is 64 characters.


def render(stack: Path) -> bytes:
    text = (stack / "user-data.sh").read_text(encoding="utf-8")
    if "%{" in text:
        sys.exit(f"{stack}: template directives (%{{) are not rendered by this check")
    text = re.sub(
        r'\$\{files\["([^"]+)"\]\}',
        lambda m: base64.b64encode((stack / "files" / m.group(1)).read_bytes()).decode(),
        text,
    )
    text = re.sub(r"(?<!\$)\$\{[A-Za-z0-9_]+\}", STAND_IN, text)
    return text.replace("$${", "${").encode("utf-8")


def main() -> None:
    failed = False
    for arg in sys.argv[1:]:
        stack = Path(arg)
        rendered = render(stack)
        gzipped = "base64gzip(templatefile(" in (stack / "main.tf").read_text(encoding="utf-8")
        size = len(gzip.compress(rendered)) if gzipped else len(rendered)
        form = "gzip" if gzipped else "plain"
        print(f"{stack}: {size} of {LIMIT_BYTES} bytes ({form}; {len(rendered)} plain)")
        if size > LIMIT_BYTES:
            print(f"{stack}: over EC2's user-data limit", file=sys.stderr)
            failed = True
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
