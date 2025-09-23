### Установка:

Чтобы начать настройку сервера, просто выполните следующую команду в терминале:
```sh
bash <(curl -Ls https://github.com/blagodaren/reverse-marz-node/raw/main/marz-node-script.sh)
```
В панели Marzban мастер-сервера требуется внести изменения в конфигурацию ядра xray, в inbound с TCP-REALITY нужно добавить serverName ноды по следующему примеру:

```
"serverNames": [
   "domain.com",
   "node.domain.com"
]
```

Также не забудьте добавить новый хост ноды:

![image](https://github.com/user-attachments/assets/d3c8c238-2df1-4cee-ad58-d5564bdc2693)
