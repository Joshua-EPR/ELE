// take resolves a sibling module; exposed flows and shapes are usable.
take modules.corpus_math

flow main() => Int {
    print(addNums(20, 22))
    print(mulNums(6, 7))
    hold v = vec(3, 4)
    print(lengthSquared(view v))
    give addNums(1, 2)
}
