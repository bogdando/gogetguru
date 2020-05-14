# A Linking Tool for Go Modules to Work With GoGuru

Linking cloned sources or extracted modules under GOPATH for Go Guru
to work with go modules AUTOMAGICALLY:
 * For each extracted pkg module by go tools, symlinks it from modules (or
   clones it from the discovered repo URL) into GOPATH. Use '-o' to
   allow symlinking modules over GOPATH contents (is destructive for repos!)
 * If the package is aliased to another repo, also creates a simlink for it:
   cloud.google.com/go -> github.com/googleapis/google-cloud-go
 * If a package is already in GOPATH, stashes cnahges, resets HEAD, then checks
   it out by the wanted version and tries to git pull, if in a branch.
 * For multi-packages in a single repo, the last processed package "wins" and
   the repo stays checked out for its only version. F.e. cloud.google.com/go:
   * has cloud.google.com/go/storage and storage/v1.2.3
   * has cloud.google.com/go/bigquery and bigquery/v3.2.1
   So the bigquery's version wins, if processed after "storage". Using '-o'
   may improve that situation by symlinking right module versions into the repo
 * The list of extracted packages (either passed in a file or args) is always
   sorted so the topmost level packages will be processed last, while the
   nested packages will go first. When read from stdin it's processed as it
   goes without changing the order of packages.

Hacks around missing [goguru modules support](https://github.com/golang/go/issues/31720)
so you can use modules with [vim-go](https://github.com/fatih/vim-go), hopefully.

Alternative approaches to this script is either vendoring:
```
  $ export GOFLAGS=-mod=vendor
```
OR hacking in go.mod files, e.g.:
```
  use replace github.com/foo/bar => ../bar
```
OR using gopls over go guru?..

## Examples
NOTE stderr redirect is needed for pipelining go tools):
```
 $ go get k8s.io/api/core/v1@latest |& gogetguru.sh
 $ go mod tidy 2>&1 | tee gogetmodules
 $ gogetguru.sh -o -f gogetmodules  # postprocess it in overwrite mode
```
Or (this also attempts to follow redirected URLs):
```
 $ gogetguru.sh k8s.io/weird.module/v1 github.com/something/odd/v3@v1.2.3
```
Example that "mirrors" the vendored modules also in the GOPATH src:
```
 $ go mod vendor |& gogetguru.sh
```
Or example for how to not mess your go.mod and go.sum in ./ :
```
 $ function ggg { (cd && GO111MODULE=on $@ |& gogetguru.sh) }
 $ ggg go get -u cats.io/a.messy.module/v1@master
```
Fetch the world example (process all a project's deps to put it in GOPATH):
```
 $ go list -m all | tail -n +2 | xargs -n1 -r -I{} echo go: extracting {} |& gogetguru
```
Fetch only direct deps for future post-processing (-f gogetmodules):
```
 $ go list -u -f \
   '{{if (not (or .Main .Indirect))}}go: extracting {{.Path}}: {{.Version}}{{end}}' \
   -m all 2>/def/null > gogetmodules
```
