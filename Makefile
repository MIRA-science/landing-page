all: schema

schema:
	$(MAKE) -C $@
	mkdir -p public
	cp index.html schema/mira.ttl schema/mira.jsonld public/
	cp -r schema/site public/schema
	cp -r previews public/previews

.PHONY: all schema
