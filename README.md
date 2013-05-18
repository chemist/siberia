Siberia
=======================
Сервер для ретрансляции радио и вещания с локальных файлов. 

Сборка и запуск
--------------

```
git clone http://github.com/chemist/radio
cd radio
cabal configure
cabal build
cabal install
```

Для локальных трансляций в правильном битрейте нужен [ffmpeg](http://www.ffmpeg.org/)
На 8000 порту веб-интерфейс. На 2000 порту вещаются потоки.

```
~/.cabal/bin/radio
```
при этом статика, логи, база радиостанций и музыка будут находиться в ~/.cabal/share/radio-0.1.0.0/

Или, легкий запуск из текущей папки
```
./start
```

Прослушивание потока по имени 3600:
```
mpg123 http://localhost:2000/3600
```

> Copyright (c) 2013 RadioVoice
