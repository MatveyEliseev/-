---
- name: Автоматическое развертывание Flask + YDB
  hosts: all
  become: yes
  gather_facts: yes
  vars:
    ydb_endpoint: "grpcs://ydb.serverless.yandexcloud.net:2135"
    ydb_database:  "/ru-central1/b1ggqkragm4esrop05kv/etn6ticqknaq7i5cdd1t" 
    app_port: 8080
    app_name: "app.internal"

  tasks:
    - name: Установить зависимости
      package:
        name:
          - python3
          - python3-pip
        state: present

    - name: Установить зависимости Python
      pip:
        name:
          - flask
          - ydb
        executable: pip3
      when: inventory_hostname == 'alt'

    - name: Копировать authorized_key.json
      copy:
        src: authorized_key.json
        dest: /opt/authorized_key.json
        mode: '0600'
      when: inventory_hostname == 'alt'

    - name: Развернуть Flask-приложение
      copy:
        dest: /opt/app.py
        content: |
          from flask import Flask
          import ydb
          import ydb.iam

          app = Flask(__name__)
          credentials = ydb.iam.ServiceAccountCredentials.from_file('/opt/authorized_key.json')

          driver = ydb.Driver(
              ydb.DriverConfig(
                  endpoint="grpcs://ydb.serverless.yandexcloud.net:2135",
                  database="/ru-central1/b1ggqkragm4esrop05kv/etn6ticqknaq7i5cdd1t",
                  credentials=credentials
              )
          )
          driver.wait(fail_fast=True, timeout=10)
          session = driver.table_client.session().create()

          def create_table():
              try:
                  session.create_table(
                      '/ru-central1/b1ggqkragm4esrop05kv/etn6ticqknaq7i5cdd1t/test',
                      ydb.TableDescription()
                      .with_primary_keys('id')
                      .with_columns(
                          ydb.Column('id', ydb.PrimitiveType.Int64),
                          ydb.Column('name', ydb.PrimitiveType.Utf8)
                      )
                  )
              except Exception:
                  pass  # уже есть

          create_table()

          @app.route('/')
          def index():
              session.transaction().execute(
                  "UPSERT INTO test (id, name) VALUES (1, 'Привет из YDB');",
                  commit_tx=True
              )
              result = session.transaction().execute(
                  "SELECT id, name FROM test;",
                  commit_tx=True
              )
              return '<br>'.join([f"{r.id}: {r.name}" for r in result[0].rows])

          if __name__ == '__main__':
              app.run(host='0.0.0.0', port={{ app_port }})
      when: inventory_hostname == 'alt'

    - name: Запустить Flask
      shell: "nohup python3 /opt/app.py &"
      async: 10
      poll: 0
      when: inventory_hostname == 'alt'

    - name: Прописать app.internal в /etc/hosts
      lineinfile:
        path: /etc/hosts
        line: "{{ hostvars['alt'].ansible_default_ipv4.address }} {{ app_name }}"
      when: inventory_hostname == 'redos'

    - name: Разрешить доступ к приложению только с redos
      iptables:
        chain: INPUT
        protocol: tcp
        destination_port: "{{ app_port }}"
        source: "{{ hostvars['redos'].ansible_default_ipv4.address }}"
        jump: ACCEPT
      when: inventory_hostname == 'alt'

    - name: Запретить остальной входящий трафик к приложению
      iptables:
        chain: INPUT
        protocol: tcp
        destination_port: "{{ app_port }}"
        jump: DROP
      when: inventory_hostname == 'alt'
