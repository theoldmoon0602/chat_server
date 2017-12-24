import std.socket;
string repr(string s) pure @safe {
	import std.array:replace;
	return "\"" ~ s.replace("\t", "\\t").replace("\r", "\\r").replace("\n", "\\n").replace("\0", "\\0") ~ "\"";
}

immutable(char[]) asUTF(ubyte[] s) {
	import std.string:assumeUTF;
	import std.algorithm:strip;
	return s.assumeUTF.strip('\0');
}

immutable(char[]) format(S...)(S args) {
	import std.traits : isBoolean, isIntegral, isAggregateType, isSomeString;
	import std.outbuffer : OutBuffer;
	auto buf = new OutBuffer();
	foreach (arg; args)
	{
		alias A = typeof(arg);
		static if (isAggregateType!A || is(A == enum))
		{
			import std.format : formattedWrite;

			formattedWrite(buf, "%s", arg);
		}
		else static if (isSomeString!A)
		{
			buf.put(arg);
		}
		else static if (isIntegral!A)
		{
			import std.conv : toTextRange;

			toTextRange(arg, buf);
		}
		else static if (isBoolean!A)
		{
			put(buf, arg ? "true" : "false");
		}
		else static if (isSomeChar!A)
		{
			put(buf, arg);
		}
		else
		{
			import std.format : formattedWrite;

			// Most general case
			formattedWrite(buf, "%s", arg);
		}
	}
	return buf.toString();
}


ptrdiff_t emit(S...)(Socket sock, S args) {
	return sock.emit(format(args));
}

ptrdiff_t emitln(S...)(Socket sock, S args) {
	return sock.emit(format(args, "\n"));
}

ptrdiff_t emit(Socket sock, string str) {
	return sock.emit(cast(ubyte[])str);
}

ptrdiff_t emit(Socket sock, ubyte[] data) {
	ptrdiff_t sent = 0;
	while (true) {
		if (!sock.isAlive) { break; }
		sent += sock.send(data[sent..$]);
		if (sent >= data.length) { break; }
	}
	return sent;
}
