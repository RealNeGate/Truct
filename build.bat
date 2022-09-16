@echo off
chcp 65001
mkdir bin

clang hexembed.c -o bin\hexembed.exe
bin\hexembed embed.lua > embed.h

if not exist luajit\src\lua51.lib (
    cd luajit\src
    msvcbuild.bat static
    cd ..\..
)

clang main.c luajit\src\lua51.lib -I luajit\src -D_CRT_SECURE_NO_WARNINGS -O2 -march=native -lkernel32 -luser32 -lshell32 -o bin/truct.exe
echo Done!
