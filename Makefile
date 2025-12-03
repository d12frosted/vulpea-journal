.PHONY: prepare lint test clean

prepare:
	eldev prepare

lint:
	eldev lint

test:
	eldev test

clean:
	eldev clean
