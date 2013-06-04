Siberia
=======================
Сервер для ретрансляции радио и вещания с локальных файлов. 

Сборка и запуск
--------------

```
git clone http://github.com/chemist/siberia
cd siberia
cabal configure
cabal build
cabal install
```

Веб-интерфейс на 8000 порту. Потоки вещаются с порта 2000.

```
~/.cabal/bin/siberia
```
при этом статика, логи, база радиостанций и музыка будут находиться в ~/.cabal/share/siberia-0.1.0.0/

Или, легкий запуск из текущей папки
```
./start
```

Прослушивание потока из консоли
```
mpg123 http://localhost:2000/3600
```

> Copyright (c) 2013 RadioVoice
