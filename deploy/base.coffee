require("../gulpfile.coffee")

_            = require("lodash")
$            = require("gulp-load-plugins")()
fs           = require("fs-extra")
cp           = require("child_process")
path         = require("path")
gulp         = require("gulp")
glob         = require("glob")
chalk        = require("chalk")
expect       = require("chai").expect
Promise      = require("bluebird")
obfuscator   = require("obfuscator")
runSequence  = require("run-sequence")
cypressIcons = require("@cypress/core-icons")
cypressElectron = require("@cypress/core-electron")
log          = require("./log")
meta         = require("./meta")
pkg          = require("../package.json")
konfig       = require("../lib/konfig")
cache        = require("../lib/cache")
appData      = require("../lib/util/app_data")
Fixtures     = require("../spec/server/helpers/fixtures")

# pkgr     = Promise.promisify(pkgr)
fs       = Promise.promisifyAll(fs)
zipName  = "cypress.zip"

class Base
  constructor: (os, @options = {}) ->
    _.defaults @options,
      version:          null

    @zipName      = zipName
    @osName       = os
    @uploadOsName = @getUploadNameByOs(os)

  buildPathToAppFolder: ->
    path.join meta.buildDir, @osName

  buildPathToZip: ->
    path.join @buildPathToAppFolder(), @zipName

  getUploadNameByOs: (os) ->
    {
      darwin: "osx64"
      linux:  "linux64"
      win32:  "win64"
    }[os]

  getVersion: ->
    @options.version ? fs.readJsonSync(@distDir("package.json")).version

  copyFiles: ->
    @log("#copyFiles")

    copy = (src, dest) =>
      dest ?= src
      dest = @distDir(dest.slice(1))

      fs.copyAsync(src, dest)

    fs
      .removeAsync(@distDir())
      .bind(@)
      .then ->
        fs.ensureDirAsync(@distDir())
      .then ->
        [
          ## copy root files
          copy("./package.json")
          copy("./config/app.yml")
          copy("./lib/html")
          copy("./lib/public")
          copy("./lib/scaffold")
          copy("./lib/ipc")

          ## copy entry point
          copy("./index.js", "/src/index.js")

          ## copy coffee src files
          copy("./lib/controllers",         "/src/lib/controllers")
          copy("./lib/electron",            "/src/lib/electron")
          copy("./lib/modes",               "/src/lib/modes")
          copy("./lib/util",                "/src/lib/util")
          copy("./lib/api.coffee",          "/src/lib/api.coffee")
          copy("./lib/automation.coffee",   "/src/lib/automation.coffee")
          copy("./lib/cache.coffee",        "/src/lib/cache.coffee")
          copy("./lib/config.coffee",       "/src/lib/config.coffee")
          copy("./lib/cwd.coffee",          "/src/lib/cwd.coffee")
          copy("./lib/cypress.coffee",      "/src/lib/cypress.coffee")
          copy("./lib/environment.coffee",  "/src/lib/environment.coffee")
          copy("./lib/errors.coffee",       "/src/lib/errors.coffee")
          copy("./lib/exception.coffee",    "/src/lib/exception.coffee")
          copy("./lib/exec.coffee",         "/src/lib/exec.coffee")
          copy("./lib/file_server.coffee",  "/src/lib/file_server.coffee")
          copy("./lib/files.coffee",        "/src/lib/files.coffee")
          copy("./lib/fixture.coffee",      "/src/lib/fixture.coffee")
          copy("./lib/ids.coffee",          "/src/lib/ids.coffee")
          copy("./lib/konfig.coffee",       "/src/lib/konfig.coffee")
          copy("./lib/launcher.coffee",     "/src/lib/launcher.coffee")
          copy("./lib/logger.coffee",       "/src/lib/logger.coffee")
          copy("./lib/project.coffee",      "/src/lib/project.coffee")
          copy("./lib/reporter.coffee",     "/src/lib/reporter.coffee")
          copy("./lib/request.coffee",      "/src/lib/request.coffee")
          copy("./lib/routes.coffee",       "/src/lib/routes.coffee")
          copy("./lib/saved_state.coffee",  "/src/lib/saved_state.coffee")
          copy("./lib/scaffold.coffee",     "/src/lib/scaffold.coffee")
          copy("./lib/screenshots.coffee",  "/src/lib/screenshots.coffee")
          copy("./lib/server.coffee",       "/src/lib/server.coffee")
          copy("./lib/socket.coffee",       "/src/lib/socket.coffee")
          copy("./lib/stats.coffee",        "/src/lib/stats.coffee")
          copy("./lib/stdout.coffee",       "/src/lib/stdout.coffee")
          copy("./lib/updater.coffee",      "/src/lib/updater.coffee")
          copy("./lib/upload.coffee",       "/src/lib/upload.coffee")
          copy("./lib/user.coffee",         "/src/lib/user.coffee")
          copy("./lib/video.coffee",        "/src/lib/video.coffee")
          copy("./lib/watchers.coffee",     "/src/lib/watchers.coffee")

        ]
      .all()

  convertToJs: ->
    @log("#convertToJs")

    ## grab everything in src
    ## convert to js
    new Promise (resolve, reject) =>
      gulp.src(@distDir("src/**/*.coffee"))
        .pipe $.coffee()
        .pipe gulp.dest(@distDir("src"))
        .on "end", resolve
        .on "error", reject

  distDir: (src) ->
    args = _.compact [meta.distDir, @osName, src]
    path.join args...

  obfuscate: ->
    @log("#obfuscate")

    ## obfuscate all the js files
    new Promise (resolve, reject) =>
      ## grab all of the js files
      files = glob.sync @distDir("src/**/*.js")

      ## root is src
      ## entry is cypress.js
      ## files are all the js files
      opts = {root: @distDir("src"), entry: @distDir("src/index.js"), files: files}

      obfuscator.concatenate opts, (err, obfuscated) =>
        return reject(err) if err

        ## move to lib
        fs.writeFileSync(@distDir("index.js"), obfuscated)

        resolve(obfuscated)

  cleanupSrc: ->
    @log("#cleanupSrc")

    fs.removeAsync @distDir("/src")

  cleanupPlatform: ->
    @log("#cleanupPlatform")

    cleanup = =>
      Promise.all([
        fs.removeAsync path.join(meta.distDir, @osName)
        fs.removeAsync path.join(meta.buildDir, @osName)
      ])

    cleanup().catch(cleanup)

  ## add tests around this method
  updatePackage: ->
    @log("#updatePackage")

    version = @options.version

    fs.readJsonAsync(@distDir("package.json")).then (json) =>
      json.env = "production"
      json.version = version if version
      json.scripts = {}

      @log("#settingVersion: #{json.version}")

      delete json.devDependencies
      delete json.bin

      fs.writeJsonAsync(@distDir("package.json"), json)

  npmInstall: ->
    @log("#npmInstall")

    new Promise (resolve, reject) =>
      attempts = 0

      npmInstall = =>
        attempts += 1

        cp.exec "npm install --production", {cwd: @distDir()}, (err, stdout, stderr) ->
          if err
            if attempts is 3
              fs.writeFileSync("./npm-install.log", stderr)
              return reject(err)

            console.log chalk.red("'npm install' failed, retrying")
            return npmInstall()

          resolve()

      npmInstall()

  elBuilder: ->
    @log("#elBuilder")

    fs.readJsonAsync(@distDir("package.json"))
    .then (json) =>
      cypressElectron.install({
        dir: @distDir()
        dist: @buildPathForElectron()
        platform: @osName
        "app-version": json.version
      })

  uploadFixtureToS3: ->
    @log("#uploadFixtureToS3")

    @uploadToS3("osx64", "fixture")

  getManifest: ->
    requestPromise(konfig("desktop_manifest_url")).then (resp) ->
      console.log resp

  fixture: (cb) ->
    @dist()
      .then(@uploadFixtureToS3)
      .then(@cleanupPlatform)
      .then ->
        @log("Fixture Complete!", "green")
        cb?()
      .catch (err) ->
        @log("Fixture Failed!", "red")
        console.log err

  log: ->
    log.apply(@, arguments)

  gulpBuild: ->
    @log("#gulpBuild")

    new Promise (resolve, reject) ->
      runSequence "app:build", (err) ->
        if err then reject(err) else resolve()

  createCyCache: (project) ->
    cache.path = cache.path.replace("development", "production")

    # cache = path.join(@buildPathToAppResources(), ".cy", "production", "cache")

    cache.write({
      USER: {authToken: "abc123"}
      PROJECTS: [project]
    })

  removeCyCache: ->
    ## empty the .cy/production folder
    # cache = path.join(@buildPathToAppResources(), ".cy", "production")

    cache.path = cache.path.replace("development", "production")

    cache.remove()

  _runProjectTest: ->
    @log("#runProjectTest")

    Fixtures.scaffold()

    e2e = Fixtures.projectPath("e2e")

    runProjectTest = =>
      new Promise (resolve, reject) =>
        env = _.omit(process.env, "CYPRESS_ENV")

        sp = cp.spawn @buildPathToAppExecutable(), ["--run-project=#{e2e}", "--spec=cypress/integration/simple_passing_spec.coffee"], {stdio: "inherit", env: env}
        sp.on "exit", (code) ->
          if code is 0
            resolve()
          else
            reject(new Error("running project tests failed with: '#{code}' errors."))

    @createCyCache(e2e)
    .then(runProjectTest)
    .then ->
      Fixtures.remove()
    .then =>
      @removeCyCache()

  _runFailingProjectTest: ->
    @log("#runFailingProjectTest")

    Fixtures.scaffold()

    e2e = Fixtures.projectPath("e2e")

    verifyScreenshots = =>
      screenshot1 = path.join(e2e, "cypress", "screenshots", "simple failing spec -- fails1.png")
      screenshot2 = path.join(e2e, "cypress", "screenshots", "simple failing spec -- fails2.png")

      Promise.all([
        fs.statAsync(screenshot1)
        fs.statAsync(screenshot2)
      ])

    runProjectTest = =>
      new Promise (resolve, reject) =>
        env = _.omit(process.env, "CYPRESS_ENV")

        sp = cp.spawn @buildPathToAppExecutable(), ["--run-project=#{e2e}", "--spec=cypress/integration/simple_failing_spec.coffee"], {stdio: "inherit", env: env}
        sp.on "exit", (code) ->
          if code is 2
            resolve()
          else
            reject(new Error("running project tests failed with: '#{code}' errors."))

    @createCyCache(e2e)
    .then(runProjectTest)
    .then(verifyScreenshots)
    .then ->
      Fixtures.remove()
    .then =>
      @removeCyCache()

  _runSmokeTest: ->
    @log("#runSmokeTest")

    smokeTest = =>
      new Promise (resolve, reject) =>
        rand = "" + Math.random()

        cp.exec "#{@buildPathToAppExecutable()} --smoke-test --ping=#{rand}", (err, stdout, stderr) ->
          stdout = stdout.replace(/\s/, "")

          return reject(err) if err

          if stdout isnt rand
            throw new Error("Stdout: '#{stdout}' did not match the random number: '#{rand}'")
          else
            resolve()

    verifyAppPackage = =>
      new Promise (resolve, reject) =>
        cp.exec "#{@buildPathToAppExecutable()} --return-pkg", (err, stdout, stderr) ->
          return reject(err) if err

          stdout = JSON.parse(stdout)

          try
            expect(stdout.env).to.eq("production")
          catch err
            console.log(stdout)
            return reject(err)

          resolve()

    smokeTest().then(verifyAppPackage)

  cleanupCy: ->
    appData.removeSymlink()

  build: ->
    Promise
    .bind(@)
    .then(@cleanupPlatform)
    .then(@gulpBuild)
    .then(@copyFiles)
    .then(@updatePackage)
    .then(@convertToJs)
    .then(@obfuscate)
    .then(@cleanupSrc)
    .then(@npmInstall)
    .then(@npmInstall)
    .then(@elBuilder)
    .then(@runSmokeTest)
    .then(@runProjectTest)
    .then(@runFailingProjectTest)
    .then(@cleanupCy)
    .then(@codeSign) ## codesign after running smoke tests due to changing .cy
    .then(@verifyAppCanOpen)
    .return(@)

module.exports = Base