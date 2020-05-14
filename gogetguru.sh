#!/bin/bash
#
# Linking cloned sources or extracted modules under GOPATH for Go Guru
# to work with go modules AUTOMAGICALLY:
# - For each extracted pkg module by go tools, symlinks it from modules (or
#   clones it from the discovered repo URL) into GOPATH. Use '-o' to
#   allow symlinking modules over GOPATH contents (is destructive for repos!)
# - If the package is aliased to another repo, also creates a simlink for it:
#   cloud.google.com/go -> github.com/googleapis/google-cloud-go
# - If a package is already in GOPATH, stashes cnahges, resets HEAD, then checks
#   it out by the wanted version and tries to git pull, if in a branch.
# - For multi-packages in a single repo, the last processed package "wins" and
#   the repo stays checked out for its only version. F.e. cloud.google.com/go:
#   - has cloud.google.com/go/storage and storage/v1.2.3
#   - has cloud.google.com/go/bigquery and bigquery/v3.2.1
#   So the bigquery's version wins, if processed after "storage". Using '-o'
#   may improve that situation by symlinking right module versions into the repo
# - The list of extracted packages (either passed in a file or args) is always
#   sorted so the topmost level packages will be processed last, while the
#   nested packages will go first. When read from stdin it's processed as it
#   goes without changing the order of packages.
#
# Hacks around missing goguru modules support https://github.com/golang/go/issues/31720
# so you can use modules with https://github.com/fatih/vim-go, hopefully.
#
# Alternative approaches to this script is either vendoring:
# $ export GOFLAGS=-mod=vendor
# OR hacking in go.mod files, e.g.:
# use replace github.com/foo/bar => ../bar
# OR using gopls over go guru?..
#
# Example (NOTE stderr redirect is needed for pipelining go tools):
# $ go get k8s.io/api/core/v1@latest |& gogetguru.sh
# $ go mod tidy 2>&1 | tee gogetmodules
# $ gogetguru.sh -o -f gogetmodules  # postprocess it in overwrite mode
#
# Or (this also attempts to follow redirected URLs):
# $ gogetguru.sh k8s.io/weird.module/v1 github.com/something/odd/v3@v1.2.3
#
# Example that "mirrors" the vendored modules also in the GOPATH src:
# $ go mod vendor |& gogetguru.sh
#
# Or example for how to not mess your go.mod and go.sum in ./ :
# $ function ggg { (cd && GO111MODULE=on $@ |& gogetguru.sh) }
# $ ggg go get -u cats.io/a.messy.module/v1@master
#
# Fetch the world example (process all a project's deps to put it in GOPATH):
# $ go list -m all | tail -n +2 | xargs -n1 -r -I{} echo go: extracting {} |& gogetguru
#
# Fetch only direct deps for future post-processing (-f gogetmodules):
# $ go list -u -f \
#   '{{if (not (or .Main .Indirect))}}go: extracting {{.Path}}: {{.Version}}{{end}}' \
#   -m all 2>/def/null > gogetmodules
#
usage(){
  cat << EOF
  Usage:
    -h - print this usage info and exit
    -i - only show info on discovered symlinks in GOPATH/src
         (the tool works only with a first entry of the GOPATH)
    -c - cleanup symlinks of GOPATH[0]/pkg modules into sources
    -f - a file from which to read the info about packages
         extracted by misc go tools
    -o - overwrite mode that perfers linking modules over repos
         It only post-processes packages from -f <file> or args
    <arg1 ... argN> - a list of packages to process directly
    NOTE: when used in a pipe, it reads info about extracted
          packages from stdin and processes it on fly
          (use it like: go get ... 2>&1 | gogetguru.sh).
EOF
}

gitclone(){ # args: url, local path
  # leverages results cached in global histry
  local rc=1
  local p="$1"
  local s="$2"
  # an entry format: <url> <rc> (or followURL's shared cache)
  local cached=$(cat $histry | grep -m 1 "$p ")
  echo $cached | grep -q 'follow ' && cached=$(echo $cached | awk -F"follow " '{print $2}')
  if [ "$cached" ]; then
    rc=$(echo $cached | awk '{print $2}')
  else
    [ -d "$s" ] && rm -r "$s" 2>/dev/null  # purge if only empty dir
    mkdir -p "${s%/*}" 2>/dev/null
    git clone "$p" "$s" >/dev/null 2>&1
    rc=$?
    echo "$p $rc" >> $histry  # don't dedup it
  fi
  return $rc
}

function followURL(){ # args: URL to follow - recursively, if redirected and
  # look for aliases & clone by discivered URL (with naive HTTP redirect features)
  # TODO find a better way to discover the real source repo, like via go list?
  local rc=1
  local res
  local loc
  local cached
  local pfl
  local sfl
  # an entry format: follow <url> <rc> [<sfl> <pfl>], ignores chached git clone results
  cached=$(cat $histry | grep -m 1 "follow $1 ")
  if [ "$cached" ]; then
    rc=$(echo $cached | awk '{print $3}')
    if [ $rc -eq 0 ]; then
      sfl=$(echo $cached | awk '{print $4}')
      pfl=$(echo $cached | awk '{print $5}') 
    fi
  else
    #set +x
    local doc=$(curl -sLk "$1")
    local madness='.*content=".*?\n?.*?\s(?<url>https:\/\/\S+\b)({.*)?"/ && print $+{url}'
    local xmlKungfu='/id="pkg-files".*?\n?.*?(?<url>https:\/\/\S+\b)({.*)?"/ && print $+{url}'
    local goimp=$(echo $doc | tr -s '\n' ' ' | perl -l -0777ne "/meta name=\"go-source\"$madness" | tail -1)
    goimp=${goimp:-$(echo $doc | tr -s '\n' ' ' | perl -l -0777ne "/meta name=\"go-import\"$madness" | tail -1)}
    goimp=${goimp:-$(echo $doc | tr -s '\n' ' ' | perl -l -0777ne "$xmlKungfu" | tail -1)}
    #set -x
    goimp=$(echo $goimp | awk -F"/tree/|/blob/" '{print $1}')
    pfl=$(echo $goimp | awk -F'https://' '{print $2}')
    if [ -z "${goimp}${pfl}" ]; then
      echo "follow $1 1" >> $histry
      return 1
    fi
    sfl="${GOPATH}/src/${pfl%.git}"
    pfl="${pfl%.git}"
    if [ -d "$(readlink -f $sfl)/.git" ]; then
      sfl=$(readlink -f "$sfl")
      pfl=$(echo $sfl | awk -F"$GOPATH/src/" '{print $2}')
      rc=0
    else
      res=$(curl -sIk $goimp)
      if echo $res | grep -iq '301 moved'; then
        loc=$(echo $res | perl -lne '/location:\s*(?<url>\S+\b)/ && print $+{url}')
        loc="${loc:-$goimp}"
        if [ "${loc%.git*}" != "${1%.git*}" ]; then
          followURL "${loc}"
          rc=$?
        else
          gitclone "${loc:-$goimp}" "${sfl}"
          rc=$?
        fi
      elif echo $res | grep -i '200 ok'; then
        gitclone "${loc:-$goimp}" "${sfl}"
        rc=$?
      else
        rc=1  # failed parsing HTTP response
      fi
    fi
  fi
  if [ $rc -eq 0 ]; then
    pf="${pf:-$pfl}"; sf="${sf:-$sfl}"  # return discovered alias and path
    echo "follow $1 0 $sf $pf" >> $histry  # don't dedup it
  fi
  return $rc
}

cloneit(){  # args: package name and ver.
  # returns 0 if checked out the wanted version of a package in sources
  local s
  local p
  local pf
  local sf
  local sfb
  local fl
  local rc=1
  local nl="$(echo $1 | tr '[:upper:]' '[:lower:]')"
  local bn="$(basename $1)"
  local bnl="$(basename $nl)"
  local ver=${2:-master}
  local mver
  local cver
  local levels
  local cached
  
  f=''
  oldf=''
  IFS=$' '
  for p in "$1" "${1%/*/*/*}" "${1%/*}" "${1%/*/*}" "${1%/*/*/*/*}"; do  # also search a 4 levels up
    [ $(echo $p | grep -o \/ | wc -w) -gt 0 ] || continue
    echo $levels | grep -q "$p " && continue
    levels="${levels} $p"
  done
  for p in $levels; do
    [ $(echo $p | grep -o \/ | wc -w) -gt 0 ] || continue 
    s="$GOPATH/src/$p"
    f="$p"
    oldf="$f"
    rc=1
    if [ -d "$(readlink -f $s)/.git" ]; then  # continue to check out
      s=$(readlink -f "$s")
      f=$(echo $s | awk -F"$GOPATH/src/" '{print $2}')
      rc=0
      break
    else
      gitclone "https://$p" "$s"
      rc=$?
      if [ $rc -ne 0 ]; then
        f=''
        followURL "https://$p" # updates history of URLs in global histry
        rc=$?
        if [ $rc -eq 0 ]; then
          f="$pf"  # the discovered alias from URL
          s="$sf"  # the discovered local path
        fi
      fi
    fi
    [ $rc -eq 0 ] && break
  done
  [ $rc -eq 0 ] || return 1
  
  # try to check out what we have here
  git -C "$s" stash >/dev/null 2>&1
  git -C "$s" reset --hard HEAD >/dev/null 2>&1
  git -C "$s" clean -fd >/dev/null 2>&1
  if [ "$ver" != "master" ]; then
    # ascend versions up or try by commit sha until found something appropriate...
    mver=$(git --no-pager -C "$s" branch -r 2>/dev/null | grep -o "${ver%.*}.*" | uniq)
    git --no-pager -C "$s" tag | grep -q -e "$ver" -e "$mver" ||\
      git -C "$s" remote update >/dev/null 2>&1
    if [ -z "$mver" ]; then  # try to match it by a major version
      mver=$(git --no-pager -C "$s" branch -r 2>/dev/null | grep -o "${ver%.*.*}" | uniq)
    fi
    # also try to match it by commit sha
    cver=$(echo $ver | awk -F'-' '{print $NF}')
    git --no-pager -C "$s" log -n1 --oneline "$cver"  >/dev/null 2>&1 && mver=$cver
    # for multipkg repos, try matching basename/(m)ver tag as well
    git -C "$s" checkout "$bnl/$ver"  -b "$bnl/$ver"  >/dev/null 2>&1 ||\
    git -C "$s" checkout "$bnl/$ver"                  >/dev/null 2>&1 ||\
    git -C "$s" checkout "$bn/$ver"   -b "$bn/$ver"   >/dev/null 2>&1 ||\
    git -C "$s" checkout "$bn/$ver"                   >/dev/null 2>&1 ||\
    git -C "$s" checkout "$ver"       -b "$ver"       >/dev/null 2>&1 ||\
    git -C "$s" checkout "$ver"                       >/dev/null 2>&1 ||\
    git -C "$s" checkout "$cver"                      >/dev/null 2>&1 ||\
    git -C "$s" checkout "$bnl/$mver" -b "$bnl/$mver" >/dev/null 2>&1 ||\
    git -C "$s" checkout "$bnl/$mver"                 >/dev/null 2>&1 ||\
    git -C "$s" checkout "$bn/$mver"  -b "$bn/$mver"  >/dev/null 2>&1 ||\
    git -C "$s" checkout "$bn/$mver"                  >/dev/null 2>&1 ||\
    git -C "$s" checkout "$mver"      -b "$mver"      >/dev/null 2>&1 ||\
    git -C "$s" checkout "$mver"                      >/dev/null 2>&1 ||\
    git -C "$s" checkout master                       >/dev/null 2>&1 # a poor man's match
    rc=$?
  else
    git -C "$s" checkout master >/dev/null 2>&1
    rc=$?
  fi
  git -C "$s" pull --ff-only >/dev/null 2>&1
  
  # check if found a camelcase match:
  #   ($1)googleapis/gnostic/OpenAPIv3 -> (f)googleapis/gnostic (has ./openapiv3)
  # or found an alias on other paths/repos:
  #   ($1)Masterminds/semver/v3 -> (f)Masterminds/semver (has no ./v3 dir)
  if [ ! -d "$GOPATH/src/$1" -a "$f" ]; then
    fl=$(echo $f | tr '[:upper:]' '[:lower:]')
    if echo $nl | grep -q "$fl"; then  # is a subpath of $1.lower (googleapis/gnostic)
      sfb=$(echo "$nl" | awk -F"$fl" '{print $2}') # rightmost part (openapiv3(/...))
      fl="${f}${sfb}"
      if [ -d "$GOPATH/src/$fl" ]; then
        f="$fl"; oldf="$1"; # signal to the caller that f->oldf has to be symlinked
      fi
    fi
    if [ "$f" != "$1" ]; then
      oldf="$1" # signal to the caller that f->oldf has to be symlinked 
    fi
  fi
  return $rc
}

clean=1; info=1; overwrite=1; file='';args=''
while (( $# )); do
  case "$1" in
    '-h') usage >&2; exit 0 ;;
    '-c') clean=0;;
    '-i') info=0;;
    '-f') shift; file=${1:--};;
    '-o') overwrite=0;;
    *) [[ $1 =~ ^- ]] || args="${1},$args";;
  esac
  shift
done
[ -z "$args" ] && file=${file:--}  # read from stdin, if no file name given
if [ "$file" = '-' -o -z "$file" ] && [ $overwrite -eq 0 -a -z "$args" ]; then
  echo 'gogetguru: -o (overwrite mode) requires <args> or -f <file>. Ignoring it!'
  overwrite=1
fi

# works with a single entry path yet
GOP=${GOPATH:-$HOME/go}
GOPATH=$(echo $GOP | awk -F':' '{print $1}')
[ -L "$GOPATH" ] && GOPATH=$(readlink -f "$GOPATH")

if [ $clean -eq 0 ]; then
  echo "gogetguru: cleaning off previously symlinked pkg/mods"
  IFS=$'\n'
  for l in $(find "$GOPATH/src" -type l); do
    readlink -f "$l" | grep -q '/pkg/mod/' && rm -f "$l"
    rc=$?
  done
  exit $rc
fi

# purge only broken symlinks
find "$GOPATH/src" -type l ! -exec test -e {} \; -print |\
  xargs -n1 -r rm -f

if [ $info -eq 0 ]; then
  echo "gogetguru: global info on symlinks (relative to $GOPATH/src):"
  IFS=$'\n'
  for l in $(find "$GOPATH/src" -type l); do
    src=$(echo $l | perl -pe 's,[^\s]\S+/src/,,g')
    dst=$(readlink -f "$l" | perl -pe 's,[^\s]\S+/src/,,g')
    printf "%-55s%4s%s\n" $src '-> ' $dst
  done
  exit 0
fi

modfile=/tmp/gogetmodules
if [ "$args" ]; then
  :> "$modfile"
  IFS=,
  for a in $args; do
    v=$(echo $a | awk -F"@" '{print $2}')
    echo "gogetguru: extracting ${a%@*} ${v:-master}" >> "$modfile"
  done
  file="$modfile"
fi
sort "$file" -o "$modfile"
file="$modfile"

found=''   # list of found (processed OK) packages for this run
histry=$(mktemp /tmp/tmp.XXXXXXXXXX) # history of processed URLs for this run
trap 'rm -f ${histry}' EXIT INT HUP
while read -r m; do
  echo $m
  [[ $m =~ "extracting" ]] || continue
  name=$(echo $m | awk -F':' '{print $2}' | awk '{print $2}')
  ver=$(echo $m | awk -F':' '{print $2}' | awk '{print $3}' | awk -F'+incompatible' '{print $1}')
  echo "$found" | grep -q "$name@$ver" && continue  # found on the src paths
  sname=$(basename "$name")
  dname=$(dirname "$GOPATH/pkg/mod/$name")

  # check if symlink exists and already matches
  readlink -f "$GOPATH/src/$name" | grep -q "${ver}" && continue

  # check if it already exists in modules (pick it only if version matched)
  fm=''
  fm=$(find ${dname} -name "${sname}@*" 2>/dev/null | grep -m1 "$ver")
  if [ "$fm" ]; then
    fm=$(echo $fm | awk -F'.tmp' '{print $1}')
    ver=$(echo $fm | awk -F'@' '{print $2}' | awk -F'/' '{print $1}')
  else
    fm=$(find ${dname}@* -type d -name "${sname}" 2>/dev/null | grep -m1 "$ver")
    fm=$(echo $fm | awk -F'.tmp' '{print $1}')
    if [ "$fm" ]; then
      ver=$(echo $fm | awk -F'@' '{print $2}' | awk -F'/' '{print $1}')
    fi
  fi
 
  # create a symlink of a module into expected src path
  if [ "$fm" ] && [ ! -d "$(readlink -f $GOPATH/src/$name)/.git" -o -L "$GOPATH/src/$name" -o $overwrite -eq 0 ]; then
    rm -r "$GOPATH/src/$name" 2>/dev/null  # purge dir if empty
    [ $overwrite -eq 0 ] && rm -rf "$GOPATH/src/$name"
    mkdir -p "$GOPATH/src/${f%/*}" 2>/dev/null
    ln -sf "$fm" "$GOPATH/src/$name"
    echo "gogetguru: $name@$ver: linked module as $GOPATH/src/$name"
    found="$name@$ver $found"
  fi

  # was it already/before symlinked from a module?
  [ "$fm" ] && continue

  # tracks history of attempted URLs and rcs in global histry
  cloneit "$name" "$ver"  # sets f and oldf != f, if f is a discovered alias
  rc=$?
  if [ $rc -eq 0 -a "$f" -a "$oldf" -a "$oldf" != "$f" ]; then  # discovered alias should be symlinked
    found="$oldf@$ver $found"
    if [ ! -d "$(readlink $GOPATH/src/$oldf)/.git" -o -L "$GOPATH/src/$oldf" -o $overwrite -eq 0 ]; then
      rm -r "$GOPATH/src/$oldf" 2>/dev/null  # purge dir if empty
      [ $overwrite -eq 0 ] && rm -rf "$GOPATH/src/$oldf"
      mkdir -p "$GOPATH/src/${oldf%/*}" 2>/dev/null
      ln -sf "$GOPATH/src/$f" "$GOPATH/src/$oldf"
      echo "gogetguru: $name@$ver: linked alias $f as $GOPATH/src/$oldf"
    fi
  elif [ $rc -eq 0 -a "$f" ]; then
    found="$name@$ver $found"
    [ "$f" != "$name" ] && found="$f@$ver $found"
  fi
  [ -d "$GOPATH/src/$name" ] || echo "gogetguru: $name@$ver: could not be located (try vendoring it?)"
done < <(cat -- "$file")
