"""Проверка IPA физического iPhone; подпись выполняет пользователь отдельно."""
import plistlib
import struct
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as z:
    root = 'Payload/AniPolka.app/'
    info = plistlib.loads(z.read(root + 'Info.plist'))
    assert info['CFBundleIdentifier'] == 'com.zakitkh.anipolka'
    assert info['CFBundleExecutable'] == 'AniPolka'
    assert info['CFBundleDisplayName'] == 'АниПолка'
    assert info['CFBundleSupportedPlatforms'] == ['iPhoneOS']
    assert info['UIDeviceFamily'] == [1]
    assert info['MinimumOSVersion'] == '17.0'
    b = z.read(root + 'AniPolka')
    assert b[:4] == b'\xcf\xfa\xed\xfe'
    assert struct.unpack_from('<I', b, 4)[0] == 0x0100000C, 'Expected ARM64'
    # LC_BUILD_VERSION platform must be iOS (2), not iOS simulator (7).
    offset, platforms = 32, []
    for _ in range(struct.unpack_from('<I', b, 16)[0]):
        cmd, size = struct.unpack_from('<II', b, offset)
        if cmd == 0x32:
            platforms.append(struct.unpack_from('<I', b, offset + 8)[0])
        offset += size
    assert platforms == [2], platforms
    assert root + 'Assets.car' in z.namelist()
    assert not any(n.endswith(('.p12', '.mobileprovision')) for n in z.namelist())
    print('Проверено: АниПолка, ARM64 Mach-O, платформа iPhoneOS, иконка, отдельный bundle ID, без signing secrets.')
