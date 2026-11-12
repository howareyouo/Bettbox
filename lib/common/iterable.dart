extension IterableExt<T> on Iterable<T> {
  Iterable<T> separated(T separator) sync* {
    final iterator = this.iterator;
    if (!iterator.moveNext()) return;

    yield iterator.current;

    while (iterator.moveNext()) {
      yield separator;
      yield iterator.current;
    }
  }
}

extension ListExt<T> on List<T> {
  void truncate(int maxLength) {
    if (maxLength == 0) {
      return;
    }
    if (length > maxLength) {
      removeRange(0, length - maxLength);
    }
  }
}

extension MapExt<K, V> on Map<K, V> {
  V updateCacheValue(K key, V Function() callback) {
    if (this[key] == null) {
      this[key] = callback();
    }
    return this[key]!;
  }
}
