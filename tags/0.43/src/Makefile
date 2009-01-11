.SILENT:

CP=cp

all: install

install: soiled.swf
	$(CP) soiled.swf ../html/soiled.swf

CompileTime.hx:
	date '+class CompileTime { public static var time = "%Y-%m-%d %H:%M:%S";}'> CompileTime.hx

soiled.swf: CompileTime.hx Telnet.hx VT100.hx Client.hx
	@echo Compiling soiled.swf
	haxe compile.hxml
	rm CompileTime.hx
