# ClearYourWin

Основной репозиторий: [DSIFYB/ClearYourWin](https://github.com/DSIFYB/ClearYourWin).

Лёгкий набор инструментов для ИИ-агента, который помогает диагностировать и оптимизировать Windows.
По подходу вдохновлён [cleanyourtv](https://github.com/Gathin23/cleanyourtv): инструкции + небольшие
штатные инструменты + резервная копия + проверка результата. Код написан отдельно для Windows.

Первая версия работает по запросу, без установки, фонового процесса и сторонних библиотек.
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

## Границы первой версии

Это рабочий диагностический CLI и инструкции для агента, а не законченный универсальный оптимизатор.
Автоматического удаления мусора/программ, изменения служб и драйверов, веб-панели и агента через
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
- [План и критерии готовности](docs/plan.md)
- [Подключение к ПК](docs/connection.md)
- [Что проверено и что требует приёмки](docs/verification.md)
- [Сценарий агента](PROMPT.md)

Технические основания: [PowerShell Remoting](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_remote_requirements),
[Win32_Process](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-process),
[Get-AuthenticodeSignature](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.security/get-authenticodesignature),
[Get-MpComputerStatus](https://learn.microsoft.com/en-us/powershell/module/defender/get-mpcomputerstatus).
