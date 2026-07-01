import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  print('Starting ultimate stress test for --fast-launch template rendering...');
  
  final tmpDir = Directory.systemTemp.createTempSync('webos_stress_test');
  print('Working directory: ${tmpDir.path}');

  const int numProjects = 15;
  final List<Future<void>> tasks = [];

  for (int i = 0; i < numProjects; i++) {
    tasks.add(_createProject(tmpDir, 'stress_app_$i'));
  }

  final startTime = DateTime.now();
  
  // Run all creations concurrently to test for race conditions/file locks
  try {
    await Future.wait(tasks);
  } catch (e) {
    print('❌ Stress test failed with exception: $e');
    exit(1);
  }

  final duration = DateTime.now().difference(startTime);
  
  print('✅ Successfully created $numProjects projects concurrently in ${duration.inMilliseconds}ms');

  // Verify all projects have the correct keepAlive flag
  int verifiedCount = 0;
  for (int i = 0; i < numProjects; i++) {
    final appInfoFile = File('${tmpDir.path}/stress_app_$i/webos/meta/appinfo.json');
    if (!appInfoFile.existsSync()) {
      print('❌ Missing appinfo.json in stress_app_$i');
      exit(1);
    }
    
    final content = appInfoFile.readAsStringSync();
    final json = jsonDecode(content);
    
    if (json['keepAlive'] != true) {
      print('❌ keepAlive is not true in stress_app_$i: $content');
      exit(1);
    }
    
    if (json['bgImage'] != 'icon.png') {
      print('❌ bgImage is missing or incorrect in stress_app_$i: $content');
      exit(1);
    }
    
    verifiedCount++;
  }

  print('✅ All $verifiedCount projects verified to have perfect Fast Launch configurations.');
  
  // Cleanup
  tmpDir.deleteSync(recursive: true);
  print('🧹 Cleanup complete. STRESS TEST PASSED.');
}

Future<void> _createProject(Directory tmpDir, String name) async {
  final process = await Process.run(
    'dart',
    [
      'bin/flutter_webos.dart',
      'create',
      '--platforms',
      'webos',
      '--fast-launch',
      '${tmpDir.path}/$name'
    ],
    workingDirectory: Directory.current.path,
  );

  if (process.exitCode != 0) {
    throw Exception('Failed to create project $name:\nSTDOUT: ${process.stdout}\nSTDERR: ${process.stderr}');
  }
}
