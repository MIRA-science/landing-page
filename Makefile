all: schema

schema:
	$(MAKE) -C $@
	mkdir -p public
	cp index.html how-the-schema-works.html schema/mira.ttl schema/mira.jsonld schema/mira.shacl public/
	cp -r schema/site public/schema
	cp -r blog public/
	cp -r library public/

.PHONY: all schema
