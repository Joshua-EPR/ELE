shape Box {
    text: Text
}

flow main() {
    change texts: List of[Text] = List["old{1}"]
    texts[0] = "new{2}"
    print(texts[0])

    change boxes: List of[Box] = List[Box(text: "old{3}")]
    boxes[0] = Box(text: "new{4}")
    print(boxes[0].text)

    change nested: List of[List of[Int]] = List[]
    nested@push(List[1])
    nested[0] = List[2, 3]
    print(nested[0][1])
}
