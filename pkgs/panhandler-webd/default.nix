{
  lib,
  buildGoModule,
  buildNpmPackage,
  dbus,
}:
let
  ui = buildNpmPackage {
    pname = "panhandler-ui";
    version = "0.1.0";
    src = ./web;
    npmDepsHash = "sha256-sf6EwM3J6KKNye+RpHfG9kW3AL8WvVZYJlaq1RRStGc=";
    dontNpmInstall = true;
    installPhase = "cp -r dist $out";
  };
in
buildGoModule {
  pname = "panhandler-webd";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./go.mod
      ./go.sum
      (lib.fileset.fileFilter (f: f.hasExt "go") ./.)
      ./dist/.gitkeep
    ];
  };
  vendorHash = "sha256-y+3dL8WEiN4PDHLX9/iNijS20wUheiJ+mZrM7af69G0=";
  env.CGO_ENABLED = 0;
  nativeCheckInputs = [ dbus ];
  ldflags = [
    "-s"
    "-w"
  ];
  # The SPA is embedded via go:embed all:dist.
  preBuild = "cp -r ${ui}/. dist/";
  passthru = { inherit ui; };
  meta.mainProgram = "panhandler-webd";
}
