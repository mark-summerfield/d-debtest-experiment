tokei -s lines -f -t=D -e tests
dscanner --styleCheck \
    | grep -v app.d.*Public.declaration.*is.undocumented
git status
