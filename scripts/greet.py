#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "click",
# ]
# ///

import click


@click.group()
def cli():
    """A simple greeting CLI with hello and goodbye commands."""
    pass


@cli.command()
@click.option('--name', default='World', help='Name to greet.')
def hello(name):
    """Say hello to someone."""
    click.echo(f'Hello, {name}!')


@cli.command()
@click.option('--name', default='World', help='Name to say goodbye to.')
def goodbye(name):
    """Say goodbye to someone."""
    click.echo(f'Goodbye, {name}!')


if __name__ == '__main__':
    cli()
