import json
import strformat
import osproc
import strutils
import re
import sequtils
import net
import os
import streams

let context: SslContext = newContext()

var
    socket: Socket

echo "Fetching releases file"

socket = newSocket()
wrapSocket(context, socket)

socket.connect("1.1.1.1", Port(443))
socket.send(
    "GET /dns-query?name=raw.githubusercontent.com&type=A HTTP/1.0\r\n" &
    "Host: cloudflare-dns.com\r\n" &
    "Accept: application/dns-json\r\n\r\n"
)

var
    response: string
    chunk: string
    chunkSize: int

response = ""

while true:
    chunk = ""

    chunkSize = socket.recv(data = chunk, size = 1024, timeout = 3000)

    if chunkSize < 1:
        break

    response.add(chunk)

socket.close()

var
    headers, body: string

(headers, body) = response.split("\r\n\r\n", maxsplit = 1)

let dnsAnswer: JsonNode = parseJson(body)

var address: string

for answer in dnsAnswer["Answer"]:
    address = answer["data"].getStr()
    if address.isIpAddress():
        break

socket = newSocket()
wrapSocket(context, socket)

socket.connect(address, Port(443))
socket.send(
    "GET /tachiyomiorg/tachiyomi-extensions/repo/index.min.json HTTP/1.0\r\n" &
    "Host: raw.githubusercontent.com\r\n\r\n"
)

response = ""

while true:
    chunk = ""

    chunkSize = socket.recv(data = chunk, size = 1024, timeout = 3000)

    if chunkSize < 1:
        break

    response.add(chunk)

socket.close()

(headers, body) = response.split("\r\n\r\n", maxsplit = 1)

let extensionsData: JsonNode = parseJson(body)

echo "Checking extensions"

var
    output: string
    exitCode: int

(output, exitCode) = execCmdEx("pm list packages -3")

if exitCode != 0:
    raise newException(ValueError, "Can't get packages list")

var
    installedVersionName: string
    installedversionCode: string
    matches: array[2, string]

var packages: seq[string] = newSeq[string]()

let pattern: Regex = re(r".*versionCode=([0-9]+).+versionName=([0-9\.]+).*", flags = {reDotAll, reMultiLine})

for package in output.strip().split("\n"):
    var splitedPackage: seq[string] = package.split(":")

    var packageId: string = splitedPackage[1]

    if not packageId.startsWith("eu.kanade.tachiyomi.extension"):
        continue

    packages.add(packageId)

let totalPackages: int = len(packages)

echo fmt"Found {totalPackages} extensions"

if totalPackages < 1:
    quit(0)

var
    apkFile: FileStream
    temporaryFile: string

echo "Checking for updates"

for extension in packages:

    (output, exitCode) = execCmdEx(fmt"dumpsys package {extension}")

    if exitCode != 0:
        raise newException(ValueError, "Can't get package dump")

    if not match(output, pattern, matches, 2):
        raise newException(ValueError, "Can't extract versionName and versionCode")

    (installedversionCode, installedVersionName) = toSeq(matches)

    for extensionData in extensionsData:
        if extensionData["pkg"].getStr() == extension:
            if extensionData["code"].getInt() > parseInt(installedversionCode):
                echo fmt"""{extensionData["name"].getStr()} ({installedVersionName} > {extensionData["version"].getStr()})"""
                
                (output, exitCode) = execCmdEx("mktemp")
                
                if exitCode != 0:
                    raise newException(ValueError, "Can't create temporary file")
                
                temporaryFile = output.strip()
                
                apkFile = newFileStream(temporaryFile, fmWrite)
                
                socket = newSocket()
                wrapSocket(context, socket)
                
                socket.connect(address, Port(443))
                socket.send(
                    "GET /tachiyomiorg/tachiyomi-extensions/repo/apk/" & 
                    extensionData["apk"].getStr() & " HTTP/1.0\r\n" &
                    "Host: raw.githubusercontent.com\r\n\r\n"
                )

                echo fmt"Downloading to {temporaryFile}"

                response = ""

                while true:
                    chunk = ""
                
                    chunkSize = socket.recv(data = chunk, size = 1024, timeout = 3000)
                
                    if chunkSize < 1:
                        break
                    
                    response.add(chunk)

                (headers, body) = response.split("\r\n\r\n", maxsplit = 1)

                apkFile.write(body)
                
                socket.close()
                apkFile.close()

                echo fmt"Downloaded {len(body)} bytes"

                echo "Attempting to install"
                
                (output, exitCode) = execCmdEx(fmt"pm install -r {temporaryFile}")

                removeFile(temporaryFile)

                if exitCode != 0:
                    raise newException(ValueError, fmt"Can't install apk file: {output}")
                
                echo "Install successful"

quit()
