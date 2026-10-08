# InvestHelper Infrastructure

Локальный дипломный стенд на Vagrant, VirtualBox и Ansible.

## Топология

| VM | IP | CPU | RAM | Сервисы |
|---|---|---:|---:|---|
| `control` | `192.168.56.5` | 1 | 1 ГБ | Ansible |
| `ci` | `192.168.56.10` | 2 | 4 ГБ | Jenkins, Docker Registry, cAdvisor |
| `app` | `192.168.56.20` | 2 | 3 ГБ | Docker Compose, InvestHelper, cAdvisor |
| `monitoring` | `192.168.56.30` | 2 | 3 ГБ | Prometheus, Grafana, Alertmanager, Blackbox Exporter |

Все машины имеют NAT-интерфейс для доступа в интернет и host-only интерфейс
`192.168.56.0/24`. Node Exporter устанавливается на каждую VM.

## Запуск

Установите VirtualBox, Vagrant и OpenSSH Client, затем выполните:

```powershell
vagrant up
```

VM `control` создаётся последней и автоматически запускает
`ansible-playbook playbooks/site.yml`. Повторное применение конфигурации:

```powershell
vagrant ssh control -c "cd /opt/investhelper-ansible && ansible-playbook playbooks/site.yml"
```

Проверка состояния:

```powershell
vagrant status
vagrant ssh control -c "cd /opt/investhelper-ansible && ansible all -m ping"
```

## Загрузка VM на Windows

Vagrant ждёт доступности SSH до 600 секунд. Сообщение `Fixed port collision`
означает автоматический выбор свободного порта и само по себе не является ошибкой.
Если ожидание завершается тайм-аутом, сначала проверьте `vagrant ssh <имя>`:
гостевая ОС может закончить загрузку уже после завершения команды `up`.

В журнале `%USERPROFILE%\VirtualBox VMs\investhelper-<имя>\Logs\VBox.log`
строки `AMD-V is not available`, `NEMR3Init: Snail execution mode is active`
и большие задержки `Giving up catch-up attempt` указывают на работу через
гипервизор Windows и замедление исполнения VM.
[Oracle описывает конфликт VirtualBox с Hyper-V](https://docs.oracle.com/en/virtualization/virtualbox/7.2/user/Troubleshooting.html).
Для использования аппаратной виртуализации напрямую отключите компоненты
Hyper-V, Virtual Machine Platform и Windows Hypervisor Platform в компонентах
Windows, затем перезагрузите компьютер. Это затронет WSL2 и программы,
использующие Hyper-V. Изоляция ядра и целостность памяти также могут удерживать
гипервизор включённым; отключение этих защит снижает безопасность Windows.

Увеличение тайм-аута даёт больше времени на загрузку, но не устраняет конфликт.
После тайм-аута и успешной проверки SSH можно завершить настройку командой
`vagrant up`. Если VM так и не отвечает, попробуйте
`vagrant reload <имя> --no-provision` и повторно проверьте SSH.

## Адреса сервисов

- Jenkins: <http://192.168.56.10:8080>
- Registry API: <http://192.168.56.10:5000/v2/>
- InvestHelper: <http://192.168.56.20:8080>
- Grafana: <http://192.168.56.30:3000>
- Prometheus: <http://192.168.56.30:9090>
- Alertmanager: <http://192.168.56.30:9093>

Начальные логины Jenkins и Grafana: `admin` / `change-me-now`. Их необходимо
заменить перед использованием стенда вне изолированной локальной сети.

Jenkins автоматически получает плагины и multibranch job `InvestHelper`,
который сканирует публичный GitHub-репозиторий раз в минуту.

## Деплой из Jenkins

`Jenkinsfile` находится в репозитории приложения. Все стадии выполняются на
узле `ci`: установка зависимостей, линтеры, сборка Docker-образов backend/frontend,
автотесты собранного приложения и публикация артефактов для каждой ветки.
Образы публикуются в `192.168.56.10:5000`; frontend-архив, отчёт JUnit,
логи контейнеров и метаданные образов сохраняются в Jenkins. Deploy по SSH
вызывает `deploy-investhelper` на `app`, используя уже протестированные образы.
Ansible создаёт отдельный ключ Jenkins и закрепляет SSH host key машины `app`.

Деплой выполняется автоматически для веток `main`/`master` после успешных
Lint, Build, Test и Publish. Флаг `RUN_DEPLOY` больше не используется.
Jenkins опрашивает SCM каждые две минуты, multibranch job обнаруживает ветки
периодическим сканированием. `APP_VERSION` задаёт префикс тега; номер сборки,
Git SHA и хеш имени ветки делают тег уникальным.
По умолчанию `DEPLOY_ENV=prod` публикует приложение на порту 8080,
`staging` — на 8082, отдельным Compose-проектом. Скрипт ждёт готовности обоих
контейнеров и проверяет `/health` и `/api/health`.

Для существующего стенда примените изменения инфраструктуры:

```powershell
vagrant provision control
```

Затем отправьте обновлённый Jenkinsfile в Git-репозиторий приложения и запустите
Build with Parameters в Jenkins. На `app` версия последнего успешного деплоя
сохраняется в `/opt/investhelper/.deploy-prod.env` или `.deploy-staging.env`.
Файл `.env` с секретами остаётся на `app` и управляется Ansible.

Роль Jenkins устанавливает плагин `junit` для отчётов автотестов. Тесты
поднимают отдельный Compose-проект на `ci`, не затрагивая приложение на `app`.
Внешние уведомления пока пропущены по согласованию; соответствующий обязательный
критерий диплома остаётся невыполненным.

## Секреты приложения

Для TLS T-Invest роль `app` собирает отдельный набор CA из системных сертификатов
Ubuntu и публичных Russian Trusted Root/Sub CA. Он монтируется только в backend
как `/app/certs/tinkoff-ca.pem` и задаётся через `TINKOFF_SSL_CA_FILE`.
Проверка сертификатов остаётся включённой. Публичные сертификаты в
`ansible/roles/app/files` получены по HTTPS с
`https://gu-st.ru/content/lending/russian_trusted_root_ca_pem.crt` и
`https://gu-st.ru/content/lending/russian_trusted_sub_ca_pem.crt`.
[Инструкция Т-Банка](https://developer.tbank.ru/docs/tls-settings).
После изменения набора CA повторно примените роль и пересоздайте backend
через `deploy-investhelper` с текущим тегом образа.

Значения по умолчанию находятся в `ansible/inventory/group_vars/all.yml` и пригодны
только для первоначального запуска. Секреты приложения следует хранить в
зашифрованном файле:

```powershell
vagrant ssh control
cd /opt/investhelper-ansible
ansible-vault create inventory/group_vars/vault.yml
```

Пример содержимого:

```yaml
jenkins_admin_password: "strong-password"
grafana_admin_password: "strong-password"
tinkoff_token: "token"
gemini_api_key: ""
groq_api_key: ""
```

После изменения переменных повторно запустите playbook с `--ask-vault-pass`.

## Деплой приложения

Роль `app` устанавливает `/usr/local/bin/deploy-investhelper`. После того как
pipeline собрал и отправил оба образа в Registry, деплой выполняется на VM
`app` командой:

```bash
sudo deploy-investhelper <git-sha-or-build-number>
```

Ожидаемые имена образов:

```text
192.168.56.10:5000/investhelper-backend:<version>
192.168.56.10:5000/investhelper-frontend:<version>
```

Текущий `Jenkinsfile` репозитория приложения использует старую схему
`vm2/vm3` и не публикует Docker-образы. Его нужно обновить под этот контракт
отдельным изменением в `InvestHelper.App`.
