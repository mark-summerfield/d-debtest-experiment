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
alias Unit = void[0]; // These two lines allow me to use AAs as sets
enum unit = Unit.init;
alias MaybeKeyValue = Tuple!(string, "key", string, "value", bool, "ok");
struct DoneMessage {}

struct Deb {
    string name;
    string description;
    Unit[string] tags; // set of tags

    Deb* copy() const {
        Deb* deb = new Deb;
        deb.name = name;
        deb.description = description;
        foreach (key; tags.byKey)
            deb.tags[key] = unit;
        return deb;
    }

    Deb dup() const {
        Deb deb;
        deb.name = name;
        deb.description = description;
        foreach (key; tags.byKey)
            deb.tags[key] = unit;
        return deb;
    }

    bool valid() {
        import std.string: empty;
        return !name.empty;
    }

    void clear() {
        name = "";
        description = "";
        tags.clear;
    }
}

struct Model {
    import std.concurrency: Tid;

    Deb[string] debForName; // Only read once populated

    size_t length() const { return debForName.length; }

    void readPackages() {
        import std.concurrency: receive, spawn;
        import std.file: dirEntries, FileException, SpanMode;

        Tid[] tids;
        try {
            foreach (string filename; dirEntries(PACKAGE_DIR,
                                                 PACKAGE_PATTERN,
                                                 SpanMode.shallow))
                tids ~= spawn(&readPackageFile, filename);
            auto jobs = tids.length;
            while (jobs) {
                receive(
                    (immutable(Deb)* deb) {
                        debForName[deb.name] = deb.dup;
                    },
                    (DoneMessage m) { jobs--; }
                );
            }
        } catch (FileException err) {
            import std.stdio: stderr;
            stderr.writeln("failed to read packages: ", err);
        }
    }
}

void readPackageFile(string filename) {
    import std.concurrency: ownerTid, send;
    import std.file: FileException;
    import std.range: enumerate;
    import std.stdio: File, stderr;

    try {
        bool inDescription = false; // Descriptions can by multi-line
        bool inContinuation = false; // Other things can be multi-line
        Deb deb;
        auto file = File(filename);
        foreach(lino, line; file.byLine.enumerate(1))
            readPackageLine(filename, lino, line, deb, inDescription,
                            inContinuation);
        if (deb.valid)
            send(ownerTid, cast(immutable)deb.copy);
    } catch (FileException err) {
        stderr.writefln("error: %s: failed to read packages: %s",
                        filename, err);
    }
    send(ownerTid, DoneMessage());
}

void readPackageLine(const string filename, const int lino,
                     const(char[]) line, ref Deb deb,
                     ref bool inDescription, ref bool inContinuation) {
    import std.concurrency: ownerTid, send;
    import std.path: baseName;
    import std.stdio: stderr;
    import std.string: empty, startsWith, strip;

    if (strip(line).empty) {
        if (deb.valid) {
            send(ownerTid, cast(immutable)deb.copy);
        }
        else if (!deb.name.empty || !deb.description.empty ||
                 !deb.tags.empty)
            stderr.writefln("error: %s:%,d: incomplete package: %s",
                            baseName(filename), lino, deb);
        deb.clear;
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
        deb.tags[tag] = unit;
}
