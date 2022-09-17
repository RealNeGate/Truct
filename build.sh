#!/bin/bash
mkdir -p bin

cd luajit/src
make CC=cc BUILDMODE=static libluajit.a
cd ../..

cc hexembed.c -o bin/hexembed
bin/hexembed embed.lua > embed.h

cc main.c -I luajit/src -O2 -march=native -Wl,--export-dynamic luajit/src/libluajit.a -lm -ldl -o bin/truct
echo Done!
