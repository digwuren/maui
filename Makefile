VERSION = $(shell grep -x -A1 '<< VERSION >>:' maui.fab | \
    tail +2 | \
    sed -e 's/^ *//')

all: maui-$(VERSION).tar.gz maui-$(VERSION).gem

maui-$(VERSION).tar.gz: tangle-everything
	tar czvf $@ `cat Manifest.txt`

maui-$(VERSION).gem: tangle-everything
	gem build maui.gemspec

.PHONY: tangle-everything

tangle-everything:
	ruby -Ilib bin/maui maui.fab
	ruby -Ilib bin/maui README.fab README.html
