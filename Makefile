# MirrorGuard — swallow the accidental ⌘F1 display-mirroring hotkey.
#
# Release pipeline delegated to the shared `release.mk` from
# PerpetualBeta/jorvik-release. SPM project, embedded Sparkle,
# dual-ship (.zip + .pkg).

BUNDLE_NAME      := MirrorGuard
BUNDLE_TYPE      := app
PRODUCT_NAME     := MirrorGuard.app
BUNDLE_ID        := cc.jorviksoftware.MirrorGuard
BUILD_SYSTEM     := spm
SPM_PRODUCT      := MirrorGuard

PACKAGE_TYPE     := zip
ALSO_SHIP_PKG    := true
EMBEDDED_FRAMEWORKS := Sparkle
ENTITLEMENTS     := MirrorGuard.entitlements

include ../jorvik-release/release.mk
