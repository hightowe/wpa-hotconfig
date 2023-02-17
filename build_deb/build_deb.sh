#!/bin/bash

# NOTE: run this script as follows:
#
# $ fakeroot ./build.sh

# This script builds PACKAGE using the temp BUILD_DIR
PACKAGE="wpa-hotconfig"
BUILD_DIR="./root"

if [ "$(id -u)" != "0" ]; then
  echo "The \"id -u\" command did not return uid=0."
  echo "Did you forger to run with fakeroot?"
  exit
fi

if [ ! -d ./debian ]; then
  echo "No ./debian directory!"
  exit
fi

if [ -e "$BUILD_DIR" ]; then
  echo "FATAL ERROR: a file or directory already exists where I need"
  echo "to place the temporary build directory: $BUILD_DIR"
  exit
fi

# Expect to find the program to release in our parent dir
RELEASE="../wpa_integrate_ssid.pl"
if [ ! -f "$RELEASE" ]; then
  echo "Failed to find a release!"
  exit;
fi

RELDIR=$(dirname "$RELEASE")
VERSTR=$(egrep '^my \$VERSION' "$RELEASE" | sed -e 's/^my \$//g' -e 's/;$//' -e 's/ //g' -e "s/\"/'/g")
eval "$VERSTR"  # evaling: VERSION='1.2.1'
RELNUM=$VERSION

echo "Found: $RELNUM at $RELEASE."
read -d'' -s -n1 -p "Is this what you want to build? (y/N)"
echo
if [ "$REPLY" != "y" ]; then
  echo "OK. Exiting..."
  exit;
fi

echo "Making temp build dir ($BUILD_DIR) without SVN directories..."
test -e "$BUILD_DIR" && rm -rf "$BUILD_DIR"
cp -a ./debian "$BUILD_DIR"
find "$BUILD_DIR" -type d -name .svn | xargs rm -rf
find "$BUILD_DIR" -type f -name '.*.swp' | xargs rm -rf

echo "Copying $RELEASE to $BUILD_DIR/sbin/"
cp "$RELEASE" "$BUILD_DIR/sbin/"

echo "Copying changelog into place..."
cp ../changelog "$BUILD_DIR"/usr/share/doc/wpa-hotconfig/

echo "Copying /etc/ files ..."
cp -ar "$RELDIR/etc/"* "$BUILD_DIR"/etc/

echo "Making ./debian/DEBIAN/conffiles ..."
find "$BUILD_DIR"/etc/ -type f | sed "s%^$BUILD_DIR%%" > "$BUILD_DIR"/DEBIAN/conffiles

#echo "Making man page ..."
#MAN_PAGE="$BUILD_DIR/usr/share/man/man1/basalsure.1"
#pod2man --center="Basalsure" --release="$RELNUM" "../basalsure.pod" > "$MAN_PAGE"
#( cd $(dirname "$MAN_PAGE") && ln -s basalsure.1 basalsure.py.1 )

echo "Updating package version in ./debian/DEBIAN/control"
cat ./debian/DEBIAN/control | sed "s/__VERSION__/$RELNUM/" > "$BUILD_DIR"/DEBIAN/control
egrep -i '^version:' "$BUILD_DIR"/DEBIAN/control

echo "Running \"chown -R root.root\" over the temp dir"
chown -R root.root "$BUILD_DIR"
if [ "$?" != "0" ]; then
  echo "The chown -R failed. Did you forget to run with fakeroot?"
  echo "Bailing out. You'll need to cleanup temp dir: $BUILD_DIR"
  exit
fi

RELEASE_BINFILE=$(basename "$RELEASE")
RELEASE_BINFILE="/sbin/$RELEASE_BINFILE"
echo "Running \"chmod 0755\" for $RELEASE_BINFILE"
chmod 0755 "$BUILD_DIR$RELEASE_BINFILE"

# Chmod 755 ./debian/DEBIAN/{pre,post}{inst,rm}
for maintsh in "$BUILD_DIR"/DEBIAN/{pre,post}{inst,rm}; do
  if [ -f "$maintsh" ]; then
    echo "Running \"chmod 0755\" for $maintsh"
    chmod 755 "$maintsh"
  fi
done

# Add my symlinks
#echo "Adding symlinks..."

PKGBASE=${PACKAGE}-${RELNUM}
DEBFILE="./"${PKGBASE}"-1.deb"

# Build the package
echo "Building the package $DEBFILE ..."
dpkg-deb --build "$BUILD_DIR" ${DEBFILE}

# Remove the temp. directory
echo "Done.  Cleaning up..."
rm -rf "$BUILD_DIR"

echo
echo "Package Information:"
dpkg -I ${DEBFILE}

echo
echo "Package Contents:"
dpkg --contents ${DEBFILE}



