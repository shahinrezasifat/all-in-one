package com.snaptube.pure.snaptube_pure

import android.os.Build
import java.io.File
import java.util.zip.ZipFile

/** Selects the base and compatible configuration APKs from a single-module bundletool archive. */
internal fun unpackUpdateApks(bundle: File, destination: File): List<File> {
    val abiNames = setOf("arm64_v8a", "armeabi_v7a", "x86_64", "x86", "riscv64")
    val limit = 1024L * 1024 * 1024
    ZipFile(bundle).use { archive ->
        val candidates = archive.entries().asSequence().filter {
            !it.isDirectory && it.name.matches(Regex("splits/[a-zA-Z0-9_.-]+\\.apk"))
        }.toList()
        require(candidates.size in 1..128 && candidates.all { it.name.startsWith("splits/base-") })
        val base = candidates.single { it.name == "splits/base-master.apk" }
        val abiEntries = candidates.filter {
            it.name.substringAfter("splits/base-").removeSuffix(".apk") in abiNames
        }
        val selectedAbi = Build.SUPPORTED_ABIS.firstNotNullOfOrNull { abi ->
            abiEntries.firstOrNull { it.name == "splits/base-${abi.replace('-', '_')}.apk" }
        }
        require(abiEntries.isEmpty() || selectedAbi != null)
        val selected = listOf(base) + candidates.filter {
            it != base && (it !in abiEntries || it == selectedAbi)
        }
        require(selected.all { it.size in 1..limit } && selected.sumOf { it.size } <= limit)
        require(selected.map { it.name }.toSet().size == selected.size)
        return selected.map { entry ->
            val file = File(destination, entry.name.substringAfterLast('/'))
            archive.getInputStream(entry).use { input ->
                file.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var remaining = entry.size
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        remaining -= read
                        require(remaining >= 0)
                        output.write(buffer, 0, read)
                    }
                    require(remaining == 0L)
                }
            }
            file
        }
    }
}
