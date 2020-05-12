#!/bin/bash -x
#
# Linking cloned sources or extracted modules under GOPATH for Go Guru
# to work with go modules AUTOMAGICALLY:
# - For each extracted pkg module by go tools, symlinks it from
#   modules into GOPATH, or tries to clone it from discovered repo URL.
#   If the package local repo path differs, also creates a simlink for it.
# - If a package is already in sources, stashes cnahges, resets HEAD, then checks
#   it out by the wanted version and tries to git pull, if in a branch.
#   For multi-packages in a single repo, the last processed package "wins" and
#   the repo stays checked out for its only version.
#
# Hacks around missing goguru modules support https://github.com/golang/go/issues/31720
# so you can use modules with https://github.com/fatih/vim-go, hopefully.
#
# Alternative approaches to this script is either vendoring:
# $ export GOFLAGS=-mod=vendor
# OR hacking in go.mod files, e.g.:
# use replace github.com/foo/bar => ../bar
#
# Example (NOTE stderr redirect is needed for pipelining go tools):
# $ go get k8s.io/api/core/v1@latest |& gogetguru.sh
# $ go mod tidy 2>&1 | tee /tmp/gogetmodules
# $ gogetguru.sh -f /tmp/gogetmodules  # postprocess it
#
# Or (this also attempts to follow redirected URLs):
# $ gogetguru.sh k8s.io/weird.module/v1 github.com/something/odd/v3
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
usage(){
  cat << EOF
  Usage:
    -h - print this usage info and exit
    -i - only show info on discovered symlinks in GOPATH/src
         (the tool works only with a first entry of the GOPATH)
    -c - cleanup symlinks of GOPATH[0]/pkg modules into sources
    -f - a file from which to read the info about packages
         extracted by misc go tools
    <arg1 ... argN> - a list of packages to process directly
    NOTE: when used in a pipe, it reads info about extracted
          packages from stdin and processes it on fly
          (use it like: go get ... 2>&1 | gogetguru.sh).
EOF
}

function followURL(){ # args: URL to follow - recursively, if redirected
  # look for aliases & clone by discivered URL (with naive HTTP redirect features)
  # TODO find a better way to discover the real source repo, like via go list?
  local rc=1
  local res
  local loc
  local doc=$(curl -sLk "$1")
  local madness='.*content=".*?\n?.*?\s(?<url>https:\/\/\S+\b).*?"/ && print $+{url}'
  local goimp=$(echo $doc | tr -s '\n' ' ' | perl -l -0777ne "/meta name=\"go-source\"$madness" | tail -1)
  goimp=${goimp:-$(echo $doc | tr -s '\n' ' ' | perl -l -0777ne "/meta name=\"go-import\"$madness" | tail -1)}
  local pfl=$(echo $goimp | awk -F'https://' '{print $2}')
  [ "$goimp" -a "$pfl" ] || return 1
  local sfl="${GOPATH}/src/${pfl%.git}"
  pfl="${pfl%.git}"
  if [ -d "${sfl}/.git" ]; then
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
        res=$(echo $res | grep -i '200 ok')
        if [ "$res" -o "$loc" ]; then
          [ -d "$sfl" ] && rm -r "$sfl" 2>/dev/null  # purge if only empty dir
          mkdir -p "${sfl%/*}" 2>/dev/null
          git clone "${loc:-$goimp}" "${sfl}" >/dev/null 2>&1
          rc=$?
        else
          rc=1  # failed parsing HTTP response
        fi
      fi
    fi
  fi
  if [ $rc -eq 0 ]; then
    pf="${pf:-$pfl}"; sf="${sf:-$sfl}"
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
  local rc=1
  local bn=$(basename $1)
  local bnl=$(echo $bn | tr '[:upper:]' '[:lower:]') 
  local ver=${2:-master}
  local mver
  local cver
  local levels
  
  f=''
  oldf=''
  exists=1
  for p in "$1" "${1%/*/*/*}" "${1%/*}" "${1%/*/*}" "${1%/*/*/*/*}"; do  # also search a 4 levels up
    [ $(echo $p | grep -o \/ | wc -w) -gt 0 ] || continue
    echo $levels | grep -q "$p " && continue
    levels="${levels} $p"
  done
  for p in $levels; do
    [ $(echo $p | grep -o \/ | wc -w) -gt 0 ] || continue 
    s="$GOPATH/src/$p"
    rc=1
    if [ -L "$s" ]; then  # found a symlink, do nothing
      exists=0
      f="$p"
      return 0
    fi 
    if [ -d "${s}/.git" ]; then
      f="$p"
      if git --no-pager -C "$s" branch | grep -q "* .*$ver"; then
        rc=0
        echo "gogetguru: $p@$ver: is already in $s"
      fi
      [ $rc -eq 0 -a "$p" = "$1" ] && exists=0  # no linking required
      [ $rc -eq 0 ] && return 0  # looks already checked out
      break  # is not checked out yet
    else
      [ -d "$s" ] && rm -r "$s" 2>/dev/null  # purge if only empty dir
      mkdir -p "${s%/*}" 2>/dev/null
      git clone "https://$p" "${s}" >/dev/null 2>&1
      rc=$?
      if [ $rc -eq 0 -a "$p" = "$1" ]; then
        exists=0  # no linking required
        f="$p"
      elif [ $rc -eq 0 ]; then
        f="$p"  # linking may be required
      else
        followURL "https://$p"  # discover it by following go src/import meta
        rc=$?
        if [ $rc -eq 0 ]; then  # an alias was discovered in pf
          #echo "gogetguru: $p@$ver: known as $pf"  # only for debug use
          oldf="$p"
          p="$pf"
          sfb=$(basename $sf)
          f="$(echo "$s" | awk -F"$sfb" '{print $2}')"
          f="${p}${f}"
          s="$sf"
          break
        fi
      fi
    fi
    [ $rc -eq 0 ] && break
  done

  # try check out what was found or clonned
  git -C "$s" stash >/dev/null 2>&1
  git -C "$s" reset --hard HEAD >/dev/null 2>&1
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
    git -C "$s" checkout "$mver"                      >/dev/null 2>&1
    rc=$?
  else
    git -C "$s" checkout master >/dev/null 2>&1
    rc=$?
  fi
  git -C "$s" pull --ff-only >/dev/null 2>&1

  return $rc
}

clean=1; info=1; file=''
while (( $# )); do
  case "$1" in
    '-h') usage >&2; exit 0 ;;
    '-c') clean=0;;
    '-i') info=0;;
    '-f') shift; file=${1:--};;
    *) [[ $1 =~ ^- ]] || args="${1},$args";;
  esac
  shift
done
[ -z "$args" ] && file=${file:--}  # read from stdin, if no file name given

# works with a single entry path yet
GOP=${GOPATH:-$HOME/go}
GOPATH=$(echo $GOP | awk -F':' '{print $1}')

if [ $clean -eq 0 ]; then
  echo "gogetguru: cleaning off previously symlinked pkg/mods"
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
  for l in $(find "$GOPATH/src" -type l); do
    src="$(echo $l | perl -pe 's,[^\s]\S+/src/,,g')"
    dst="$(readlink -f $l | perl -pe 's,[^\s]\S+/src/,,g')"
    printf "%-55s%4s%s\n" $src '-> ' $dst
  done
  exit 0
fi

modfile=/tmp/gogetmodules
if [ "$args" ]; then
  :> "$modfile"
  IFS=,
  for a in $args; do
    echo "gogetguru: extracting $a master" >> "$modfile"
  done
  file="$modfile"
fi

found=''
while read -r m; do
  echo $m
  [[ $m =~ "extracting" ]] || continue
  name="$(echo $m | awk -F':' '{print $2}' | awk '{print $2}')"
  ver="$(echo $m | awk -F':' '{print $2}' | awk '{print $3}' | awk -F'+incompatible' '{print $1}')"
  echo "$found" | grep -q "$name@$ver" && continue  # found on the src paths
  sname="$(basename ${name})"
  dname="$(dirname ${GOPATH}/pkg/mod/${name})"
  cloneit "$name" "$ver"  # sets exists, f and oldf, if f is a discovered alias
  rc=$?
  if [ "$f" -a "$oldf" -a "$oldf" != "$f" ]; then  # discovered alias should be symlinked
    found="$oldf@$ver $found"
    [ -d "$GOPATH/src/$oldf" ] && rm -r "$GOPATH/src/$oldf" 2>/dev/null
    if [ ! -d "$GOPATH/src/$oldf" -o -L "$GOPATH/src/$oldf" ]; then
      mkdir -p "$GOPATH/src/${oldf%/*}" 2>/dev/null
      ln -sf "$GOPATH/src/$f" "$GOPATH/src/$oldf"
      echo "gogetguru: $name@$ver: linked alias $f as $GOPATH/src/$oldf"
      continue
    else
      echo "gogetguru: $name@$ver: alias $f will not be linked: non empty $GOPATH/src/$oldf"
      continue  # touch nothing
    fi
  elif [ "$f" ]; then
    found="$name@$ver $found"
    [ "$f" != "$name" ] && found="$f@$ver $found"  # discovered in upper layers
    readlink -f "$f" | grep -q "${ver}" && continue  # existing symlink matches
    [ ! -L "$GOPATH/src/$f" -a -d "$GOPATH/src/$f" -o $exists -eq 0 ] && continue
  fi
  [ $exists -eq 0 -a $rc -eq 0 ] && continue  # all's set and linked/checked out in src
  
  # check if it already exists in modules (pick it only if version matched)
  fm=''
  fm=$(find ${dname} -name "${sname}@*" 2>/dev/null | grep -m1 "$ver")
  if [ "$fm" ]; then
    fm=$(echo $fm | awk -F'.tmp|+incompatible' '{print $1}')
    ver=$(echo $fm | awk -F'@' '{print $2}' | awk -F'/' '{print $1}')
    #echo "gogetguru: $name@$ver: picked from modules in $fm"
  else
    fm=$(find ${dname}@* -type d -name "${sname}" 2>/dev/null | grep -m1 "$ver")
    fm=$(echo $fm | awk -F'.tmp|+incompatible' '{print $1}')
    if [ "$fm" ]; then
      ver=$(echo $fm | awk -F'@' '{print $2}' | awk -F'/' '{print $1}')
      #echo "gogetguru: $name@$ver: picked from modules in $fm"
    fi
  fi

  if [ -z "$fm" ]; then
    echo "gogetguru: $name@$ver: could not be located (try vendoring it?)"
    continue
  fi
  
  # create a symlink of a module into expected src path
  f=${f:-$name}
  [ -d "$GOPATH/src/$f" ] && rm -r "$GOPATH/src/$f" 2>/dev/null
  if [ ! -d "$GOPATH/src/$f" -o -L "$GOPATH/src/$f" ]; then
    mkdir -p "$GOPATH/src/${f%/*}" 2>/dev/null
    ln -sf "$fm" "$GOPATH/src/$f"
    echo "gogetguru: $name@$ver: linked module as $GOPATH/src/$f"
    found="$name@$ver $found"
  else
    echo "gogetguru: $name@$ver: module will not be linked: non empty $GOPATH/src/$f"
  fi
done < <(cat -- "$file")
