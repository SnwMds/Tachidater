import json
import net
import os
import osproc
import re
import sequtils
import streams
import strformat
import strutils

var
    address: string
    apkFile: FileStream
    body: string
    chunk: string
    chunkSize: int
    exitCode: int
    headers: string
    installedVersionName: string
    installedversionCode: string
    matches: array[2, string]
    output: string
    packageId: string
    packages: seq[string] = newSeq[string]()
    response: string
    socket: Socket
    splitedPackage: seq[string]
    temporaryFile: string

let
    context: SslContext = newContext()
    pattern: Regex = re(r".*versionCode=([0-9]+).+versionName=([0-9\.]+).*", flags = {reDotAll, reMultiLine})

echo "Fetching releases file"

socket = newSocket()
wrapSocket(context, socket)

socket.connect("1.1.1.1", Port(443))
socket.send(
    "GET /dns-query?name=raw.githubusercontent.com&type=A HTTP/1.0\n" &
    "Host: cloudflare-dns.com\n" &
    "Accept: application/dns-json\n\n"
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

let dnsAnswer: JsonNode = parseJson(body)

for answer in dnsAnswer["Answer"]:
    address = answer["data"].getStr()
    if address.isIpAddress():
        break

socket = newSocket()
wrapSocket(context, socket)

socket.connect(address, Port(443))
socket.send(
    "GET /tachiyomiorg/tachiyomi-extensions/repo/index.min.json HTTP/1.0\n" &
    "Host: raw.githubusercontent.com\n\n"
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

(output, exitCode) = execCmdEx("pm list packages -3")

if exitCode != 0:
    raise newException(ValueError, "Can't get packages list")

for package in output.strip().split("\n"):
    splitedPackage = package.split(":")

    packageId = splitedPackage[1]

    if not packageId.startsWith("eu.kanade.tachiyomi.extension"):
        continue

    packages.add(packageId)

let totalPackages: int = len(packages)

echo fmt"Found {totalPackages} extensions"

if totalPackages < 1:
    quit(0)

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
                    extensionData["apk"].getStr() & " HTTP/1.0\n" &
                    "Host: raw.githubusercontent.com\n\n"
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
