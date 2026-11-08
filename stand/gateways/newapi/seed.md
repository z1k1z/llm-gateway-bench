# new-api

`run.sh up newapi ...` сам вызывает `seed.sh`: админ `admin` (пароль в
`data/admin.txt`), канал `mock-a` на `http://127.0.0.1:9000` и токен `bench`
(`data/api-key.txt`). Повторный запуск ничего не дублирует.

Панель на VDS наружу не открывать, только через туннель:

```bash
ssh -L 3000:127.0.0.1:3000 root@SERVER
```

## Вручную

1. В панели создать админа.
2. Каналы, создать: тип OpenAI, адрес `http://127.0.0.1:9000`,
   ключ `sk-upstream-SENTINELUP7f3a2b`, модели `mock-fast`, `mock-realistic`.
3. Токены, создать, положить в `data/api-key.txt`.
4. Проверка:

   ```bash
   curl -s http://127.0.0.1:3000/v1/chat/completions \
     -H "Authorization: Bearer $(cat gateways/newapi/data/api-key.txt)" \
     -H 'Content-Type: application/json' \
     -d '{"model":"mock-fast","messages":[{"role":"user","content":"привет"}]}' | jq .usage
   ```

   Ответ: `{"prompt_tokens":3,"completion_tokens":64,"total_tokens":67}`.
