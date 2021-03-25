all: 
	cd openssl && cat openssl_uris | xargs wget
	cd openssl && ls *.gz |xargs -n1 tar -xzf
	dmd -g gendppfile.d && ./gendppfile
