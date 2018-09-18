# simple-jails
A simple jails manager based on [FreeBSD Jails the hard way](https://clinta.github.io/freebsd-jails-the-hard-way/)


## Sample Usage

Fetching 11.2-RELEASE version

```simple-jails.sh fetch 11.2-RELEASE```


Creating jail _thinjail1_ based on 11.2-RELEASE version

```simple-jails.sh create 11.2-RELEASE thinjail1```


Update all jails based on 11.2-RELEASE version

```simple-jails.sh update 11.2-RELEASE```


## Limitations

Currently only supports _thin_ jails.

Does not setup the interfaces automatically. (TODO)

Does not generate jails.conf automatically. (TODO)
For the meantime there is an included sample jail.conf
