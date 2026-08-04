# Spring PetClinic Build & Test Workload

Builds and tests the [Spring PetClinic](https://github.com/spring-projects/spring-petclinic)
Spring Boot sample app with Maven (`mvnw`), pinned to commit `6feeae0f…` for reproducibility.
It runs an offline `package` then `test` and reports build time and test time — a Java /
Maven developer inner-loop benchmark.

## What HOBL sets up (from `spring_petclinic_resources/spring_petclinic_prep.ps1`)

- winget: Microsoft OpenJDK 25, Git
- Clones `spring-projects/spring-petclinic` @ commit
  `6feeae0f13e0e258eedc99832416b42bb13779b1` to `<drive>\spring-petclinic`
- Pre-populates a local Maven cache so builds run fully offline

## Run it standalone (Windows)

```powershell
winget install --id Microsoft.OpenJDK.25 --source winget
winget install --id git.git --source winget

git clone https://github.com/spring-projects/spring-petclinic.git
cd spring-petclinic
git checkout 6feeae0f13e0e258eedc99832416b42bb13779b1

# Populate the Maven cache once (online)
.\mvnw.cmd -Dmaven.repo.local=..\m2-cache dependency:go-offline
.\mvnw.cmd -Dmaven.repo.local=..\m2-cache verify

# Timed workload (offline against the cache)
.\mvnw.cmd clean
.\mvnw.cmd -Dmaven.repo.local=..\m2-cache -DskipTests package -o
.\mvnw.cmd -Dmaven.repo.local=..\m2-cache test -o
```

## Notes

- The `package`/`test` phases run offline (`-o`) against the pre-populated cache.
- Default: 5 loops (build + test each loop). Works on x64 and ARM64.
