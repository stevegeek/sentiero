import * as esbuild from "esbuild";
import path from "path";
import fs from "fs";
import crypto from "crypto";
import { execSync } from "child_process";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const watching = process.argv.includes("--watch");

const ASSETS_DIR = path.join(__dirname, "..", "lib", "sentiero", "web", "assets");
const BUILD_DIR = path.join(__dirname, "_build");

// Clean output directory
function cleanAssetsDir() {
  if (fs.existsSync(ASSETS_DIR)) {
    fs.rmSync(ASSETS_DIR, { recursive: true, force: true });
  }
  fs.mkdirSync(ASSETS_DIR, { recursive: true });
}

// Hash a file's content and return first 8 hex chars of SHA256
function contentHash(filePath) {
  const content = fs.readFileSync(filePath);
  return crypto.createHash("sha256").update(content).digest("hex").slice(0, 8);
}

// Copy a vendor file with content-hash fingerprint
function copyVendorWithHash(srcPath, logicalName, ext) {
  const hash = contentHash(srcPath);
  const destName = `${logicalName}-${hash}${ext}`;
  fs.copyFileSync(srcPath, path.join(ASSETS_DIR, destName));
  return destName;
}

// Build Tailwind CSS via CLI
function buildTailwind() {
  fs.mkdirSync(BUILD_DIR, { recursive: true });
  const input = path.join(__dirname, "src", "dashboard", "style.css");
  const output = path.join(BUILD_DIR, "style.css");
  execSync(`npx @tailwindcss/cli -i ${input} -o ${output} --minify`, {
    cwd: __dirname,
    stdio: "inherit",
  });
  return output;
}

// Extract hashed filenames from esbuild metafile
function extractManifestEntries(metafile) {
  const entries = {};
  for (const [outputPath, meta] of Object.entries(metafile.outputs)) {
    if (meta.entryPoint) {
      const basename = path.basename(outputPath);
      // esbuild uses uppercase alphanumeric hashes (e.g., "dashboard-2UTCRY4Z.js")
      const match = basename.match(/^(.+)-[A-Za-z0-9]+\.(js|css)$/);
      if (match) {
        entries[match[1]] = basename;
      }
    }
  }
  return entries;
}

// Build vendor entries and return their manifest mappings
function buildVendorEntries() {
  const vendorDir = path.join(__dirname, "vendor");
  const tailwindCSS = buildTailwind();
  return {
    style: copyVendorWithHash(tailwindCSS, "style", ".css"),
    "rrweb-player": copyVendorWithHash(path.join(vendorDir, "rrweb-player.js"), "rrweb-player", ".js"),
    "rrweb-player-css": copyVendorWithHash(path.join(vendorDir, "rrweb-player.css"), "rrweb-player-css", ".css"),
  };
}

// Write combined manifest from esbuild results and vendor entries
function writeManifest(recorderMeta, dashboardMeta, vendorEntries) {
  const manifest = {
    ...extractManifestEntries(recorderMeta),
    ...extractManifestEntries(dashboardMeta),
    ...vendorEntries,
  };

  fs.writeFileSync(
    path.join(ASSETS_DIR, "manifest.json"),
    JSON.stringify(manifest, null, 2) + "\n"
  );

  console.log("Manifest:", manifest);
  return manifest;
}

// Shared build options
const recorderOptions = {
  entryPoints: [path.join(__dirname, "src", "recorder.js")],
  outdir: ASSETS_DIR,
  entryNames: "[name]-[hash]",
  bundle: true,
  minify: true,
  format: "iife",
  target: ["es2020"],
  metafile: true,
  logLevel: "info",
};

const dashboardOptions = {
  entryPoints: {
    dashboard: path.join(__dirname, "src", "dashboard", "index.js"),
    sessions_index: path.join(__dirname, "src", "dashboard", "sessions_index.js"),
    analytics: path.join(__dirname, "src", "analytics", "analytics.js"),
    heatmap: path.join(__dirname, "src", "analytics", "heatmap.js"),
    import: path.join(__dirname, "src", "analytics", "import.js"),
  },
  outdir: ASSETS_DIR,
  entryNames: "[name]-[hash]",
  bundle: true,
  minify: true,
  format: "iife",
  target: ["es2020"],
  metafile: true,
  logLevel: "info",
};

async function build() {
  cleanAssetsDir();

  const recorderResult = await esbuild.build(recorderOptions);
  const dashboardResult = await esbuild.build(dashboardOptions);
  const vendorEntries = buildVendorEntries();

  writeManifest(recorderResult.metafile, dashboardResult.metafile, vendorEntries);
}

if (watching) {
  // Initial build
  await build();

  // Track latest metafiles so we can regenerate manifest on each rebuild
  let latestRecorderMeta = null;
  let latestDashboardMeta = null;
  const vendorEntries = buildVendorEntries();

  // Plugin that rewrites manifest after each watch rebuild
  function manifestPlugin(name) {
    return {
      name: `manifest-${name}`,
      setup(build) {
        build.onEnd((result) => {
          if (result.errors.length > 0) return;
          if (name === "recorder") {
            latestRecorderMeta = result.metafile;
          } else {
            latestDashboardMeta = result.metafile;
          }
          if (latestRecorderMeta && latestDashboardMeta) {
            writeManifest(latestRecorderMeta, latestDashboardMeta, vendorEntries);
          }
        });
      },
    };
  }

  const recorderCtx = await esbuild.context({
    ...recorderOptions,
    plugins: [manifestPlugin("recorder")],
  });

  const dashboardCtx = await esbuild.context({
    ...dashboardOptions,
    plugins: [manifestPlugin("dashboard")],
  });

  // Seed the metafiles from the initial build so single-context rebuilds work
  const initialRecorder = await recorderCtx.rebuild();
  const initialDashboard = await dashboardCtx.rebuild();
  latestRecorderMeta = initialRecorder.metafile;
  latestDashboardMeta = initialDashboard.metafile;

  await recorderCtx.watch();
  await dashboardCtx.watch();
  console.log("Watching for changes...");
} else {
  await build();
}
