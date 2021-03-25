import std.array : array, split;
import std.exception : enforce;
import std.algorithm.searching : any, endsWith, startsWith, canFind;
import std.algorithm.iteration : each, filter, joiner, map;
import std.path;
import std.process;
import std.format;
import std.file;
import std.stdio;
import std.string;

auto opensslVersions() {
	return dirEntries("openssl/", "*", SpanMode.shallow)
			.filter!(h => isDir(h.name));
}

// because bash is too fucking difficult
void deleteAllButIncludes() {
	auto opensslFolder = opensslVersions();
	auto allButHeader = opensslFolder
		.map!(ssl => dirEntries(ssl.name, "*", SpanMode.depth)
			.filter!(it => !it.name.endsWith(".h"))
		)
		.joiner;

	foreach(it; allButHeader) {
		if(!isSymlink(it.name) && isFile(it.name)) {
			remove(it.name);
		}
	}
}

pure string removePrefix(string ssl) {
	import std.string : indexOf;
	ptrdiff_t idx = ssl.indexOf("include");
	return idx != - 1 ? ssl[idx .. $] : ssl;
}

pure string turnOpensslVersionIntoModuleName(string ssl) {
	import std.array : replace;
	const prefix = "openssl/openssl";
	ssl = ssl.startsWith(prefix) ? ssl[prefix.length .. $] : ssl;
	ssl = replace(ssl, "-", "_");
	ssl = replace(ssl, ".", "_");
	ssl = ssl.startsWith("_") ? ssl[1 .. $] : ssl;
	return "v" ~ ssl;
}

struct DppRslt {
	string file;
	File sOut;
	File sErr;
	Pid pid;
	int exitCode;
	bool worked;
}

DppRslt callDpp(string file) {
	string dir = dirName(file);
	string dppFN = baseName(file);

	string[] dppCall = ["dub", "run", "dpp", "--", "--keep-d-files", dppFN
		, `--include-path="include/openssl/,crypto/aes/,crypto/"`];
	auto ret = DppRslt(file
			, File(dppFN ~ ".out", "w")
			, File(dppFN ~ ".err", "w"));
	ret.pid = spawnProcess(dppCall, stdin, ret.sOut, ret.sErr, null, Config.none
			, dir);

	return ret;
}

string buildDppFile(string ver) {
	auto headers = dirEntries(ver ~ "/include", "*.h", SpanMode.depth).array;
	auto excludes =
		[ "asn1_mac.h"
		];

	string modName = turnOpensslVersionIntoModuleName(ver);
	string dppFileName = format("%s/%s.dpp", ver, modName);
	auto of = File(dppFileName, "w");
	auto ltw = of.lockingTextWriter();

	formattedWrite(ltw, "module openssl.%s;\n", modName);
	headers
		.filter!(header => !excludes
				.any!(exclude => header.name.endsWith(exclude)))
		.each!(header => {
			formattedWrite(ltw, "#include \"%s\"\n"
					, header.name.removePrefix());
		}());

	return dppFileName;
}

int main() {
	//deleteAllButIncludes();
	string[] dppFiles;
	foreach(ver; opensslVersions()) {
		dppFiles ~= buildDppFile(ver);
	}
	auto fixUpIncludes = executeShell(`find openssl -name \*.h ! -type l | xargs sed -i 's/[ ]*#[ ]*include [ ]*<\([-_a-z0-9A-Z]*\.h\)>/#include "\1"/g'`);
	enforce(fixUpIncludes.status == 0, fixUpIncludes.output);
	DppRslt[] rslts;
	foreach(dppFile; dppFiles) {
		auto tmp = callDpp(dppFile);
		rslts ~= tmp;
	}
	foreach(ref rslt; rslts) {
		rslt.exitCode = wait(rslt.pid);	
		rslt.sOut.close();
		rslt.sErr.close();
		string dFP = rslt.file[0 .. $-2];
		string dFN = baseName(dFP);
		const moreThan = exists(dFP) && readText(dFP).splitLines().length > 500;
		writefln("%s %s", dFN, moreThan);
		rslt.worked = canFind(readText(rslt.sErr.name), "undefined reference to `main")
			&& moreThan;
		writefln("%s %s", rslt.file, rslt.worked ? "Worked" : "Failed");
		if(rslt.worked) {
			copy(dFP, "source/openssl/" ~ dFN);
		}
	}
	return 0;
}
