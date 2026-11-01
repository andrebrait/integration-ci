#!/bin/sh
# git merge driver for RTLPlayground's html/app.js across upstream #716, which
# reformatted the file with `js-beautify -s 4`. Any side still in the old
# compact form is reformatted the same way before a normal 3-way merge, so PR
# branches written before #716 rebase and squash onto the new file.
# Usage (git): <this> %O %A %B   (the result is written to %A)
fmt() {
	# The old file is about 2,700-3,200 lines; the reformatted one about 5,500.
	if [ "$(wc -l < "$1")" -lt 4000 ]; then
		npx --yes js-beautify@1.15.4 -s 4 -f "$1" > "$1.fmt" && printf '\n' >> "$1.fmt" && mv "$1.fmt" "$1"
	fi
}
fmt "$1"
fmt "$2"
fmt "$3"
git merge-file --diff3 -L ours -L base -L theirs "$2" "$1" "$3"
[ $? -eq 0 ] && exit 0
# #716 used a js-beautify release that places a few blank lines differently.
# A conflict whose ours and base sides are only blank lines is that difference
# alone: theirs wins. Anything else stays a conflict, in plain merge style.
python3 - "$2" <<'EOF'
import re, sys
p = sys.argv[1]
s = open(p).read()
blk = re.compile(r'^<<<<<<< ours\n(.*?)^\|\|\|\|\|\|\| base\n(.*?)^=======\n(.*?)^>>>>>>> theirs\n', re.S | re.M)
def fix(m):
    ours, base, theirs = m.groups()
    if not ours.strip() and not base.strip():
        return theirs
    return '<<<<<<< ours\n' + ours + '=======\n' + theirs + '>>>>>>> theirs\n'
s = blk.sub(fix, s)
open(p, 'w').write(s)
sys.exit(1 if '<<<<<<< ours' in s else 0)
EOF
