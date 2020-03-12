import std.typecons: Tuple;

void main(const string[] args) {
    import std.datetime.stopwatch: AutoStart, StopWatch;
    import std.stdio: stderr, writeln;

    auto model = Model();
    auto timer = StopWatch(AutoStart.yes);
    model.readPackages();
    stderr.writefln("read %,d packages in %s", model.length, timer.peek);
    if (args.length > 1)
        foreach (deb; model.debForName)
            writeln(deb);
}

enum PACKAGE_DIR = "/var/lib/apt/lists";
enum PACKAGE_PATTERN = "*Packages";
alias MaybeKeyValue = Tuple!(string, "key", string, "value", bool, "ok");

struct Deb {
    import aaset: AAset;

    string name;
    string description;
    AAset!string tags;

    Deb dup() const {
        Deb deb;
        deb.name = name;
        deb.description = description;
        foreach (key; tags)
            deb.tags.add(key);
        return deb;
    }

    bool valid() {
        import std.string: empty;
        return !name.empty; // Some debs don't have any description
    }

    void clear() {
        name = "";
        description = "";
        tags.clear;
    }
}

struct Model {
    Deb[string] debForName; // Only read once populated

    size_t length() const { return debForName.length; }

    void readPackages() {
        import std.algorithm: max;
        import std.array: array;
        import std.parallelism: taskPool, totalCPUs;
        import std.file: dirEntries, FileException, SpanMode;

        try {
            auto filenames = dirEntries(PACKAGE_DIR, PACKAGE_PATTERN,
                                        SpanMode.shallow).array;
            auto units = max(2, (totalCPUs / 2) - 1);
            foreach (debs; taskPool.map!readPackageFile(filenames, units))
                foreach (deb; debs)
                    debForName[deb.name] = deb.dup;
        } catch (FileException err) {
            import std.stdio: stderr;
            stderr.writeln("failed to read packages: ", err);
        }
    }
}

Deb[] readPackageFile(string filename) {
    import std.file: FileException;
    import std.range: enumerate;
    import std.stdio: File, stderr;

    Deb[] debs;
    Deb deb;
    try {
        bool inDescription = false; // Descriptions can by multi-line
        bool inContinuation = false; // Other things can be multi-line
        auto file = File(filename);
        foreach(lino, line; file.byLine.enumerate(1))
            readPackageLine(debs, deb, filename, lino, line, inDescription,
                            inContinuation);
        if (deb.valid)
            debs ~= deb.dup;
    } catch (FileException err) {
        stderr.writefln("error: %s: failed to read packages: %s",
                        filename, err);
    }
    return debs;
}

void readPackageLine(ref Deb[] debs, ref Deb deb, const string filename,
                     const int lino, const(char[]) line,
                     ref bool inDescription, ref bool inContinuation) {
    import std.conv: to;
    import std.stdio: stderr;
    import std.string: empty, startsWith, strip;

    if (strip(line).empty) {
        if (deb.valid) {
            debs ~= deb.dup;
            deb.clear;
        }
        return;
    }
    if (inDescription || inContinuation) {
        if (line.startsWith(' ') || line.startsWith('\t')) {
            if (inDescription)
                deb.description ~= line;
            return;
        }
        inDescription = inContinuation = false;
    }
    immutable keyValue = maybeKeyValue(line);
    if (!keyValue.ok) 
        inContinuation = true;
    else
        inDescription = populateDeb(deb, keyValue.key, keyValue.value);
}

MaybeKeyValue maybeKeyValue(const(char[]) line) {
    import std.string: indexOf, strip;

    immutable i = line.indexOf(':');
    if (i == -1)
        return MaybeKeyValue("", "", false);
    immutable key = strip(line[0..i]).idup;
    immutable value = strip(line[i + 1..$]).idup;
    return MaybeKeyValue(key, value, true);
}

bool populateDeb(ref Deb deb, const string key, const string value) {
    import std.conv: to;

    switch (key) {
        case "Package":
            deb.name = value;
            return false;
        case "Description", "Npp-Description": // XXX ignore Npp-?
            deb.description ~= value;
            return true; // We are now in a description
        case "Tag":
            maybePopulateTags(deb, value);
            return false;
        default: return false; // Ignore "uninteresting" fields
    }
}

void maybePopulateTags(ref Deb deb, const string tags) {
    import std.regex: ctRegex, split;

    auto rx = ctRegex!(`\s*,\s*`);
    foreach (tag; tags.split(rx))
        deb.tags.add(tag);
}
