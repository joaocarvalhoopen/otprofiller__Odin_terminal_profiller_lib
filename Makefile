all:
	odin build . -out:otprof.exe -o:speed

clear:
	rm -f ./otprof.exe

run:
	./otprof.exe
