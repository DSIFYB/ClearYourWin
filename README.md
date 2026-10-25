# ClearYourWin

Основной репозиторий: [DSIFYB/ClearYourWin](https://github.com/DSIFYB/ClearYourWin).

Лёгкий набор инструментов для ИИ-агента, который помогает диагностировать и оптимизировать Windows.
По подходу вдохновлён [cleanyourtv](https://github.com/Gathin23/cleanyourtv): инструкции + небольшие
штатные инструменты + резервная копия + проверка результата. Код написан отдельно для Windows.

Инструменты работают по запросу, без установки, фонового процесса и сторонних библиотек.
Требуется Windows 10/11, **64-разрядный Windows PowerShell 5.1 или PowerShell 7**.
Начинайте без администратора; отсутствие прав видно в `sections.*.errors`.

## Быстрый старт

Откройте эту папку в своём агенте и передайте ему [PROMPT.md](PROMPT.md).
Инструменты можно запускать вручную из корня репозитория:

```powershell
powershell -NoProfile -File tools/Collect-Snapshot.ps1
powershell -NoProfile -File tools/Analyze-Snapshot.ps1 -Path reports/snapshot-ИМЯ.json
```

Первая команда напечатает точный путь нового JSON; подставьте его во вторую.
`reports/` и `backups/` исключены из Git. Файлы не перезаписываются. Сборщик не меняет
системные настройки; записывает только отчёт в указанную папку.
Если политика выполнения запрещает скрипты, используйте разрешённый организацией способ запуска;
проект не меняет политику выполнения.

## Что уже работает

| Инструмент | Результат |
| --- | --- |
| `Collect-Snapshot.ps1` | ОС, ОЗУ, процессы, интервальная загрузка CPU, число потоков, службы, драйверы, PnP-устройства, диски, автозапуск, приложения, состояние Defender, ограниченный обход TEMP |
| `Analyze-Snapshot.ps1` | Детерминированные рекомендации с доказательствами в JSON или текстовом виде |
| `Inspect-File.ps1` | SHA-256, Authenticode и метаданные одного указанного файла; файл не запускается |
| `Set-StartupEntry.ps1` | Предпросмотр или отключение **одной** записи HKCU Run с резервной копией |
| `Restore-StartupEntry.ps1` | Возврат этой записи из журнала без перезаписи существующей |
| `Collect-RemoteSnapshot.ps1` | Сбор через уже открытую PSSession, отчёт сохраняется на компьютере оператора |
| `New-CleanupPlan.ps1` | Точный список старых TEMP-файлов с лимитами, размером и идентификаторами файлов |
| `Invoke-Cleanup.ps1` | Предпросмотр или применение списка очистки с повторной проверкой каждого файла и журналом |
| `Invoke-Maintenance.ps1` | Шесть штатных операций анализа, очистки и обслуживания Windows |
| `Compare-Snapshots.ps1` | Сравнение свободной памяти, нагрузки процессов и свободного места до/после |

```powershell
# Дополнительная детализация потоков; без чтения памяти и стеков.
./tools/Collect-Snapshot.ps1 -IncludeThreads -SampleSeconds 2
# Дополнительные каталоги: только по явному указанию, с лимитами обхода.
./tools/Collect-Snapshot.ps1 -ScanRoot 'D:\Cache' -MaxScanEntries 10000 -ScanSeconds 10
./tools/Inspect-File.ps1 -Path 'C:\SomeApp\app.exe'
# По умолчанию — только план. Имя берётся из реального отчёта, не из примера.
./tools/Set-StartupEntry.ps1 -Name 'ExampleApp'
./tools/Set-StartupEntry.ps1 -Name 'ExampleApp' -Apply -WhatIf
# После согласования конкретного изменения:
./tools/Set-StartupEntry.ps1 -Name 'ExampleApp' -Apply
./tools/Restore-StartupEntry.ps1 -Path 'backups/startup-ИМЯ.json' -Apply
```

Отключение HKCU Run влияет на будущий вход текущего пользователя, не завершает уже запущенное
приложение и не управляет Task Manager StartupApproved, задачами, службами или другими профилями.
Не отключайте через этот инструмент защитные программы и средства связи/доступа.

## Очистка TEMP

```powershell
./tools/New-CleanupPlan.ps1 -Scope UserTemp -MinAgeDays 7 -MaxBytes 2GB -MaxFiles 1000
# Подставьте путь, напечатанный предыдущей командой. Сначала просмотрите список:
./tools/Invoke-Cleanup.ps1 -Path 'reports/cleanup-plan-ИДЕНТИФИКАТОР.json'
./tools/Invoke-Cleanup.ps1 -Path 'reports/cleanup-plan-ИДЕНТИФИКАТОР.json' -Apply -WhatIf
# После согласования списка:
./tools/Invoke-Cleanup.ps1 -Path 'reports/cleanup-plan-ИДЕНТИФИКАТОР.json' -Apply
```

Поддерживаются `UserTemp`, `WindowsTemp` и `Both`. WindowsTemp может требовать администратора.
Корни определяются через штатные папки Windows; произвольные каталоги и переменная TEMP не дают
права на удаление. Дополнительные каталоги из ScanRoot остаются только диагностикой.
Возраст создания **и** последней записи должен быть не меньше 7 дней. Программы и скрипты,
ссылки, системные/read-only/offline-файлы и файлы с несколькими жёсткими ссылками пропускаются.

План действует 4 часа на том же ПК и для того же SID. При применении каждый файл проверяется
снова: путь, идентификатор, размер, время. Занятые/изменённые файлы пропускаются. Удаление идёт
через проверенный Win32-дескриптор с удержанием каталогов, а не повторный вызов удаления по пути.
Код помощника — небольшой [CleanupNative.cs](lib/CleanupNative.cs), компилируется штатным Add-Type
при первом запуске; отдельный SDK не нужен. Restricted Language/WDAC могут запрещать Add-Type;
инструмент остановится, обхода политик нет.

**Удаление окончательное, без корзины и автоматического отката.** `backups/cleanup-*.jsonl` — журнал,
а не копии удалённых файлов. deletedBytes — размер обработанных файлов, не гарантия немедленного
роста свободного места. Каталоги не удаляются. Все ограничения описаны в [сценарии очистки](docs/operations.md).

## Оптимизация и обслуживание

Каждый вызов сначала показывает действие. `-Apply` запускает его, `-Apply -WhatIf` только показывает.
Права администратора требуются для DISM, SFC и работы с томами; повышение не выполняется автоматически.

| Action | Назначение |
| --- | --- |
| `AnalyzeComponentStore` | Анализ хранилища компонентов через DISM |
| `CleanComponentStore` | Штатная очистка устаревших компонентов без ResetBase и автоперезагрузки |
| `AnalyzeVolume` | Анализ выбранного тома |
| `OptimizeVolume` | Оптимизация выбранного тома, способ выбирает Windows |
| `FlushDns` | Сброс локального DNS-кэша для устранения проблем разрешения имён |
| `VerifySystemFiles` | Проверка системных файлов SFC без исправления |

```powershell
./tools/Invoke-Maintenance.ps1 -Action AnalyzeComponentStore
./tools/Invoke-Maintenance.ps1 -Action CleanComponentStore -Apply -WhatIf
./tools/Invoke-Maintenance.ps1 -Action OptimizeVolume -DriveLetter C
# Только после выбора и согласования действия, в подходящей PowerShell-сессии:
./tools/Invoke-Maintenance.ps1 -Action OptimizeVolume -DriveLetter C -Apply
./tools/Compare-Snapshots.ps1 -Before 'reports/до.json' -After 'reports/после.json'
```

Операции выполняются по одной. Запрос, результат и вывод штатных средств сохраняются в
`backups/maintenance-*/`. DNS-сброс — средство диагностики, не ускоритель интернета. DISM и
оптимизация тома могут создавать существенную нагрузку и не имеют автоматического отката;
перед выбором посмотрите [эффект и ограничения](docs/operations.md).

## Границы текущей версии

Это CLI диагностики, очистки и обслуживания с инструкциями для агента.
Массового удаления приложений, изменения служб и драйверов, веб-панели и агента через
интернет пока нет. Этапы развития описаны в [плане](docs/plan.md).
Обход дисков ограничен TEMP и явно указанными каталогами; он не является антивирусной проверкой.
Defender показывает состояние защиты, а не гарантирует отсутствие заражения. Для расследования
агент использует точечную проверку файлов и штатные средства защиты по согласованию.

Отчёт включает имена компьютера, учётной записи, пути, приложения и устройства. Не публикуйте его
без просмотра. Аргументы процессов не собираются; команды автозапуска/служб всё же могут содержать
личные данные. В удалённой сессии HKCU/TEMP относятся к учётной записи этой сессии.

## Проверки и документация

```powershell
powershell -NoProfile -File tests/Run-Tests.ps1
```

- [Архитектура и формат отчёта](docs/design.md)
- [Очистка и штатные операции](docs/operations.md)
- [План и критерии готовности](docs/plan.md)
- [Подключение к ПК](docs/connection.md)
- [Что проверено и что требует приёмки](docs/verification.md)
- [Сценарий агента](PROMPT.md)

Технические основания: [PowerShell Remoting](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_remote_requirements),
[Win32_Process](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-process),
[Get-AuthenticodeSignature](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.security/get-authenticodesignature),
[Get-MpComputerStatus](https://learn.microsoft.com/en-us/powershell/module/defender/get-mpcomputerstatus).
